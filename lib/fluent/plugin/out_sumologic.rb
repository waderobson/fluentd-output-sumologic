require 'fluent/plugin/output'
require 'net/https'
require 'yajl'

class SumologicConnection
  def initialize(endpoint, verify_ssl)
    @endpoint_uri = URI.parse(endpoint.strip)
    @verify_ssl = verify_ssl
  end

  def publish(raw_data, source_host=nil, source_category=nil, source_name=nil)
    response = http.request(request_for(raw_data, source_host, source_category, source_name))
    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to send data to HTTP Source. #{response.code} - #{response.message}"
    end
  end

  private
  def request_for(raw_data, source_host, source_category, source_name)
    request = Net::HTTP::Post.new(@endpoint_uri.request_uri)
    request.body = raw_data
    request['X-Sumo-Name'] = source_name
    request['X-Sumo-Category'] = source_category
    request['X-Sumo-Host'] = source_host
    request
  end

  def http
    # Rubys HTTP is not thread safe, so we need a new instance for each request
    client = Net::HTTP.new(@endpoint_uri.host, @endpoint_uri.port)
    client.use_ssl = true
    client.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    client
  end
end

class Fluent::Plugin::Sumologic < Fluent::Plugin::Output
  # First, register the plugin. NAME is the name of this plugin
  # and identifies the plugin in the configuration file.
  Fluent::Plugin.register_output('sumologic', self)

  helpers :compat_parameters
  DEFAULT_BUFFER_TYPE = "memory"

  config_param :endpoint, :string
  config_param :log_format, :string, default: 'json'
  config_param :log_key, :string, default: 'message'
  config_param :source_category, :string, default: ''
  config_param :source_name, :string, default: ''
  config_param :source_name_key, :string, default: 'source_name'
  config_param :source_host, :string, default: ''
  config_param :verify_ssl, :bool, default: true

  config_section :buffer do
    config_set_default :@type, DEFAULT_BUFFER_TYPE
    config_set_default :chunk_keys, ['tag']
  end

  # This method is called before starting.
  def configure(conf)
    compat_parameters_convert(conf, :buffer)
    unless conf['endpoint'] =~ URI::regexp
      raise Fluent::ConfigError, "Invalid SumoLogic endpoint url: #{conf['endpoint']}"
    end

    unless conf['log_format'] =~ /\A(?:json|text|json_merge)\z/
      raise Fluent::ConfigError, "Invalid log_format #{conf['log_format']} must be text, json or json_merge"
    end

    @sumo_conn = SumologicConnection.new(conf['endpoint'], @verify_ssl)
    super
  end

  # This method is called when starting.
  def start
    super
  end

  # This method is called when shutting down.
  def shutdown
    super
  end

  # Used to merge log record into top level json
  def merge_json(record)
    if record.has_key?(@log_key)
      log = record[@log_key].strip
      if log[0].eql?('{') && log[-1].eql?('}')
        begin
          record = JSON.parse(log).merge(record)
          record.delete(@log_key)
        rescue JSON::ParserError
          # do nothing, ignore
        end
      end
    end
    record
  end

  # Strip sumo_metadata and dump to json
  def dump_log(log)
    log.delete('_sumo_metadata')
    Yajl.dump(log)
  end

  def sumo_keys(sumo, source_name, source_category)
    source_name = sumo['source'] || source_name
    source_category = sumo['category'] || source_category
    source_host = sumo['host'] || @source_host
    return source_category, source_name, source_host
  end

  # Convert nanoseconds to milliseconds
  def sumo_timestamp(time)
    (time.to_f * 1000).to_int
  end

  def expand_placeholders(metadata)
    source_category = extract_placeholders(@source_category, metadata)
    source_name = extract_placeholders(@source_name, metadata)
    return source_category, source_name
  end

  # This method is called every flush interval. Write the buffer chunk
  def write(chunk)
    messages_list = []
    # Sort messages
    tag = chunk.metadata.tag
    source_category, source_name = expand_placeholders(chunk.metadata)

    chunk.msgpack_each do |time, record|
      # plugin dies randomly
      # https://github.com/uken/fluent-plugin-elasticsearch/commit/8597b5d1faf34dd1f1523bfec45852d380b26601#diff-ae62a005780cc730c558e3e4f47cc544R94
      next unless record.is_a? Hash
      sumo_metadata = record.fetch('_sumo_metadata', {'source' => record[@source_name_key]})
      source_category, source_name, source_host = sumo_keys(sumo_metadata,
                                                            source_name,
                                                            source_category)
      log_format =  @log_format

      # Strip any unwanted newlines
      record[@log_key].chomp! if record[@log_key]

      case log_format
        when 'text'
          log = record[@log_key]
          unless log.nil?
            log.strip!
          end
        when 'json_merge'
          log = dump_log(merge_json({:timestamp => sumo_timestamp(time)}.merge(record)))
        else
          log = dump_log({:timestamp => sumo_timestamp(time)}.merge(record))
      end

      if log
          messages_list.push(log)
      end

    end

    # Push logs to sumo
    @sumo_conn.publish(
        messages_list.join("\n"),
        source_host=source_host,
        source_category=source_category,
        source_name=source_name
    )

  end
end
