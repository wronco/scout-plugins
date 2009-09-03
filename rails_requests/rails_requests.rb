require "time"
require "stringio"

class RailsRequests < Scout::Plugin
  ONE_DAY    = 60 * 60 * 24
  TEST_USAGE = "#{File.basename($0)} log LOG max_request_length MAX_REQUEST_LENGTH last_run LAST_RUN"
  
  needs "elif"
  needs "request_log_analyzer"
  
  def build_report
    patch_elif
    
    log_path = option(:log)
    unless log_path and not log_path.empty?
      return error("A path to the Rails log file wasn't provided.","Please provide the full path to the Rails log file to analyze (ie - /var/www/apps/APP_NAME/log/production.log)")
    end
    max_length = option(:max_request_length).to_f

    report_data        = { :slow_request_rate     => 0,
                           :request_rate          => 0,
                           :average_request_length => nil }
    slow_request_count = 0
    request_count      = 0
    last_completed     = nil
    slow_requests      = ''
    total_request_time = 0.0
    last_run           = memory(:last_request_time) || Time.now
    @file_found = true # needed to ensure that the analyzer doesn't run if the log file isn't found.

    Elif.foreach(log_path) do |line|
      if line =~ /\A(Completed in (\d+)ms .+) \[(\S+)\]\Z/        # newer Rails
        last_completed = [$2.to_i / 1000.0, $1, $3]
      elsif line =~ /\A(Completed in (\d+\.\d+) .+) \[(\S+)\]\Z/  # older Rails
        last_completed = [$2.to_f, $1, $3]
      elsif last_completed and
            line =~ /\AProcessing .+ at (\d+-\d+-\d+ \d+:\d+:\d+)\)/
        time_of_request = Time.parse($1)
        if time_of_request < last_run
          break
        else
          request_count += 1
          total_request_time          += last_completed.first.to_f
          if max_length > 0 and last_completed.first > max_length
            slow_request_count += 1
            slow_requests                    += "#{last_completed.last}\n"
            slow_requests                    += "#{last_completed[1]}\n\n"
          end
        end # request should be analyzed
      end
    end
    
    # Create a single alert that holds all of the requests that exceeded the +max_request_length+.
    if (count = slow_request_count) > 0
      alert( "Maximum Time(#{option(:max_request_length)} sec) exceeded on #{count} request#{'s' if count != 1}",
             slow_requests )
    end
    # Calculate the average request time and request rate if there are any requests
    if request_count > 0
      # calculate the time btw runs in minutes
      interval = (Time.now-last_run)

      interval < 1 ? inteval = 1 : nil # if the interval is less than 1 second (may happen on initial run) set to 1 second
      interval = interval/60 # convert to minutes
      
      # determine the rate of requests and slow requests in requests/min
      request_rate                         = request_count /
                                             interval
      report_data[:request_rate]           = sprintf("%.2f", request_rate)
      
      slow_request_rate                    = slow_request_count /
                                             interval
      report_data[:slow_request_rate]      = sprintf("%.2f", slow_request_rate)
      
      # determine the average request length
      avg                                  = total_request_time /
                                             request_count
      report_data[:average_request_length] = sprintf("%.2f", avg)
    end
    remember(:last_request_time, Time.now)
    report(report_data)
  rescue Errno::ENOENT => error
    @file_found = false
    error("Unable to find the Rails log file", "Could not find a Rails log file at: #{option(:log)}. Please ensure the path is correct.")
  rescue Exception => error
    error("#{error.class}:  #{error.message}", error.backtrace.join("\n"))
  ensure
    # only run the analyzer if the log file is provided
    # this make take a couple of minutes on large log files.
    if @file_found and option(:log) and not option(:log).empty?
      generate_log_analysis(log_path)
    end
  end
  
  private
  
  def no_warnings
    old_verbose, $VERBOSE = $VERBOSE, nil
    yield
  ensure
    $VERBOSE = old_verbose
  end
  
  def generate_log_analysis(log_path)
    one_day_ago  = Time.now - (ONE_DAY + 1)
    last_summary = memory(:last_summary_time) || one_day_ago
    unless Time.now - last_summary > ONE_DAY
      remember(:last_summary_time, last_summary)
      return
    end
    
    summary      = StringIO.new
    output       = RequestLogAnalyzer::Output::FixedWidth.new(
                     summary,
                     :width      => 80,
                     :colors     => false,
                     :characters => :ascii
                   )
    log_file     = read_backwards_to_timestamp(log_path, last_summary)
    format       = RequestLogAnalyzer::FileFormat.load(:rails)
    options      = {:source_files => log_file, :output => output}
    source       = RequestLogAnalyzer::Source::LogParser.new(format, options)
    control      = RequestLogAnalyzer::Controller.new(source, options)
    control.add_filter(:timespan, :after => last_summary)
    control.add_aggregator(:summarizer)
    source.progress = nil
    format.setup_environment(control)
    no_warnings do
      control.run!
    end
    analysis =
      summary.string.sub(/Need an expert.+\nMail to.+\nThanks.+\Z/, "").strip
    
    remember(:last_summary_time, Time.now)
    summary( :command => "request-log-analyzer --after '"           +
                         last_summary.strftime('%Y-%m-%d %H:%M:%S') +
                         "' '#{log_path}'",
             :output  => analysis )
  rescue Exception => error
    error("#{error.class}:  #{error.message}", error.backtrace.join("\n"))
  end
  
  def patch_elif
    Elif.send(:define_method, :pos) do
      @current_pos + @line_buffer.inject(0) { |bytes, line| bytes + line.size }
    end
  end
  
  def read_backwards_to_timestamp(path, timestamp)
    start = nil
    Elif.open(path) do |elif|
      elif.each do |line|
        if line =~ /\AProcessing .+ at (\d+-\d+-\d+ \d+:\d+:\d+)\)/
          time_of_request = Time.parse($1)
          if time_of_request < timestamp
            break
          else
            start = elif.pos
          end
        end
      end
    end

    file = open(path)
    file.seek(start) if start
    file
  end
end
