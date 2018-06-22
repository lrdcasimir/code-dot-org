#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require_relative '../../../deployment'

ROOT = File.expand_path('../../../..', __FILE__)

# Set up gems listed in the Gemfile.
ENV['BUNDLE_GEMFILE'] ||= "#{ROOT}//Gemfile"
require 'bundler'
require 'bundler/setup'

require 'cdo/aws/s3'
require 'cdo/git_utils'
require 'cdo/rake_utils'
require 'cdo/test_flakiness'

require 'haml'
require 'json'
require 'yaml'
require 'optparse'
require 'ostruct'
require 'colorize'
require 'open3'
require 'parallel'
require 'securerandom'
require 'socket'
require 'parallel_tests/cucumber/scenarios'

require_relative './utils/selenium_browser'
require_relative './utils/selenium_constants'

require 'active_support/core_ext/object/blank'

ENV['BUILD'] = `git rev-parse --short HEAD`

GIT_BRANCH = GitUtils.current_branch
COMMIT_HASH = RakeUtils.git_revision
LOCAL_LOG_DIRECTORY = 'log'

#
# Run a set of UI tests according to the provided options.
# @param [OpenStruct] options - the configuration for this test run. See parse_options for details.
# @return [int] a status code
#
def main(options)
  $options = options
  $browsers = select_browser_configs(options)
  $lock = Mutex.new

  start_time = Time.now
  open_log_files
  report_tests_starting

  run_results = Parallel.map(browser_feature_generator, parallel_config(options.parallel_limit)) do |browser, feature|
    run_feature browser, feature, options
  end

  # If we aborted for some reason we may have no run results, and should
  # exit with a failure code.
  return 1 if run_results.nil?

  report_tests_finished start_time, run_results
  run_results.count {|feature_succeeded, _, _| !feature_succeeded}
ensure
  close_log_files
end

def parse_options
  OpenStruct.new.tap do |options|
    options.config = nil
    options.browser = nil
    options.os_version = nil
    options.browser_version = nil
    options.features = nil
    options.pegasus_domain = 'test.code.org'
    options.dashboard_domain = 'test-studio.code.org'
    options.hourofcode_domain = 'test.hourofcode.com'
    options.csedweek_domain = 'test.csedweek.org'
    options.local = nil
    options.html = nil
    options.maximize = nil

    # start supporting some basic command line filtering of which browsers we run against
    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: runner.rb [options] \
        Example: runner.rb -b chrome -o 7 -v 31 -f features/sharepage.feature \
        Example: runner.rb -d localhost:3000 -t \
        Example: runner.rb -l \
        Example: runner.rb -r"
      opts.separator ""
      opts.separator "Specific options:"
      opts.on("-c", "--config BrowserConfigName,BrowserConfigName1", Array, "Specify the name of one or more of the configs from ") do |c|
        options.config = c
      end
      opts.on("-b", "--browser BrowserName", String, "Specify a browser") do |b|
        options.browser = b
      end
      opts.on("-o", "--os_version OS Version", String, "Specify an os version") do |os|
        options.os_version = os
      end
      opts.on("-v", "--browser_version Browser Version", String, "Specify a browser version") do |bv|
        options.browser_version = bv
      end
      opts.on("-f", "--feature Feature", Array, "Single feature or comma separated list of features to run") do |f|
        options.features = f
      end
      opts.on("-l", "--local", "Use local domains. Also use local webdriver (not Saucelabs) unless -c is specified.") do
        options.local = 'true'
        options.pegasus_domain = 'localhost.code.org:3000'
        options.dashboard_domain = 'localhost-studio.code.org:3000'
        options.hourofcode_domain = 'localhost.hourofcode.com:3000'
        options.csedweek_domain = 'localhost.csedweek.org:3000'
      end
      opts.on("-p", "--pegasus Domain", String, "Specify an override domain for code.org, e.g. localhost.code.org:3000") do |p|
        if p == 'localhost:3000'
          print "WARNING: Some tests may fail using '-p localhost:3000' because cookies will not be available.\n"\
                "Try '-p localhost.code.org:3000' instead (this is the default when using '-l').\n"
        end
        options.pegasus_domain = p
      end
      opts.on("-d", "--dashboard Domain", String, "Specify an override domain for studio.code.org, e.g. localhost-studio.code.org:3000") do |d|
        if d == 'localhost:3000'
          print "WARNING: Some tests may fail using '-d localhost:3000' because cookies will not be available.\n"\
                "Try '-d localhost-studio.code.org:3000' instead (this is the default when using '-l').\n"
        end
        options.dashboard_domain = d
      end
      opts.on("--hourofcode Domain", String, "Specify an override domain for hourofcode.com, e.g. localhost.hourofcode.com:3000") do |d|
        options.hourofcode = d
      end
      opts.on("--csedweek Domain", String, "Specify an override domain for csedweek.org, e.g. localhost.csedweek.org:3000") do |d|
        options.csedweek = d
      end
      opts.on("-r", "--real_mobile_browser", "Use real mobile browser, not emulator") do
        options.realmobile = 'true'
      end
      opts.on("-m", "--maximize", "Maximize local webdriver window on startup") do
        options.maximize = true
      end
      opts.on("--circle", "Whether is CircleCI (skip failing Circle tests)") do
        options.is_circle = true
      end
      opts.on("--html", "Use html reporter") do
        options.html = true
      end
      opts.on("-a", "--auto_retry", "Retry tests that fail once") do
        options.auto_retry = true
      end
      opts.on("--retry_count TimesToRetry", String, "Retry tests that fail a given # of times") do |times_to_retry|
        options.retry_count = times_to_retry.to_i
      end
      opts.on("--magic_retry", "Magically retry tests based on how flaky they are") do
        options.magic_retry = true
      end
      opts.on("-n", "--parallel ParallelLimit", String, "Maximum number of browsers to run in parallel (default is 1)") do |p|
        options.parallel_limit = p.to_i
      end
      opts.on("--db", String, "Run scripts requiring DB access regardless of environment (otherwise restricted to development/test).") do
        options.force_db_access = true
      end
      opts.on("--fail_fast", "Fail a feature as soon as a scenario fails") do
        options.fail_fast = true
      end
      opts.on('-s', '--script Scriptname', String, 'Run tests associated with this script, or have Scriptname somewhere in the URL') do |script_name|
        f = `egrep -r "Given I am on .*#{script_name.delete(' ').downcase}" . | cut -f1 -d ':' | sort | uniq | tr '\n' ,`
        options.features = f.split ','
      end
      opts.on('--output-synopsis', 'Print a synopsis of failing scenarios') do
        options.output_synopsis = true
      end
      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end

    opt_parser.parse!(ARGV)
    # Standardize: Drop leading dot-slash on feature paths
    options.features = ARGV + (options.features || []).
      map! {|feature| feature.gsub(/^\.\//, '')}

    if options.force_db_access
      options.pegasus_db_access = true
      options.dashboard_db_access = true
    elsif ENV['CI']
      options.pegasus_db_access = true
      options.dashboard_db_access = true
    elsif rack_env?(:development)
      options.pegasus_db_access = true if options.pegasus_domain =~ /(localhost|ngrok)/
      options.dashboard_db_access = true if options.dashboard_domain =~ /(localhost|ngrok)/
    elsif rack_env?(:test)
      options.pegasus_db_access = true if options.pegasus_domain =~ /test/
      options.dashboard_db_access = true if options.dashboard_domain =~ /test/
    end

    if options.config
      options.local = false
    end
  end
end

def select_browser_configs(options)
  if options.local
    SeleniumBrowser.ensure_chromedriver_running
    return [{
      'browser': 'local',
      'name': 'ChromeDriver',
      'browserName': 'chrome',
      'version': 'latest'
    }]
  end

  browsers = JSON.parse(File.read('browsers.json'))
  if options.config
    options.config.map do |name|
      browsers.detect {|b| b['name'] == name}.tap do |browser|
        unless browser
          puts "No config exists with name #{name}"
          exit
        end
      end
    end
  else
    browsers # Use all of them
  end
end

def prefix_string(msg, prefix)
  msg.to_s.lines.map {|line| "#{prefix}#{line}"}.join
end

def open_log_files
  FileUtils.mkdir_p(LOCAL_LOG_DIRECTORY)
  $success_log = File.open("#{LOCAL_LOG_DIRECTORY}/success.log", 'w')
  $error_log = File.open("#{LOCAL_LOG_DIRECTORY}/error.log", 'w')
  $errorbrowsers_log = File.open("#{LOCAL_LOG_DIRECTORY}/errorbrowsers.log", 'w')
end

def close_log_files
  $success_log.close if $success_log
  $error_log.close if $error_log
  $errorbrowsers_log.close if $errorbrowsers_log
end

def log_success(msg)
  $success_log.puts msg
  puts msg
end

def log_error(msg)
  $error_log.puts msg
  puts msg
end

def log_browser_error(msg)
  $errorbrowsers_log.puts msg
  puts msg
end

def run_tests(env, feature, arguments, log_prefix)
  start_time = Time.now
  cmd = "cucumber #{feature} #{arguments}"
  puts "#{log_prefix}#{cmd}"
  Open3.popen3(env, cmd) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    stdout = stdout.read
    stderr = stderr.read
    cucumber_succeeded = wait_thr.value.exitstatus == 0
    return cucumber_succeeded, true, stdout, stderr, Time.now - start_time
  end
end

def browser_features
  feature = 'features/minrepro.feature'
  $browsers.map do |browser|
    arguments = ' -S' # strict mode, so that we fail on undefined steps
    scenario_count = ParallelTests::Cucumber::Scenarios.all([feature], test_options: arguments).length
    next if scenario_count.zero?
    [browser, feature]
  end.compact
end

def test_type
  'UI'
end

def report_tests_starting
  puts "Starting #{browser_features.count} <b>dashboard</b> #{test_type} tests in #{$options.parallel_limit} threads..."
end

def report_tests_finished(start_time, run_results)
  suite_duration = Time.now - start_time

  suite_success_count = 0
  failures = []
  run_results.each do |feature_succeeded, message, _|
    if feature_succeeded
      suite_success_count += 1
    else
      failures << message
    end
  end

  ChatClient.log "#{suite_success_count} succeeded.  #{failures.count} failed. " \
  "Test count: #{run_results.count}. " \
  "Total duration: #{RakeUtils.format_duration(suite_duration)}. "

  unless failures.empty?
    ChatClient.log "Failed tests: \n #{failures.join("\n")}"
  end
end

def test_run_identifier(browser, feature)
  feature_name = feature.gsub('features/', '').gsub('.feature', '').tr('/', '_')
  browser_name = browser_name_or_unknown(browser)
  "#{browser_name}_#{feature_name}"
end

def browser_name_or_unknown(browser)
  browser['name'] || 'UnknownBrowser'
end

# Retrieves / calculates flakiness for given test run identifier, giving up for
# the rest of this script execution if an error occurs during calculation.
# returns the flakiness from 0.0 to 1.0 or nil if flakiness is unknown
def flakiness_for_test(test_run_identifier)
  return nil if $stop_calculating_flakiness
  TestFlakiness.test_flakiness[test_run_identifier]
rescue Exception => e
  puts "Error calculating flakinesss: #{e.message}. Will stop calculating test flakiness for this run."
  $stop_calculating_flakiness = true
  nil
end

# Build a lambda function called by Parallel.map each time it needs a new work
# item.  It should return Parallel::Stop when there is no more work to do.
def browser_feature_generator
  return $browser_feature_generator if $browser_feature_generator

  browser_features_left = browser_features.dup

  $browser_feature_generator = lambda do
    return Parallel::Stop if browser_features_left.empty?
    browser_features_left.pop
  end
end

def parallel_config(parallel_limit)
  {
    # Run in parallel threads on CircleCI (less memory), processes on main test machine (better CPU utilization)
    in_threads: ENV['CI'] ? parallel_limit : nil,
    in_processes: ENV['CI'] ? nil : parallel_limit,

    # This 'finish' lambda runs on the main thread after each Parallel.map work
    # item is completed.
    finish: lambda do |_, _, result|
      feature_succeeded, _, _ = result
    end
  }
end

# returns the first line of the first selenium error in the html output file.
def first_selenium_error(filename)
  html = File.read(filename)
  error_regex = %r{<div class="message"><pre>(.*?)</pre>}m
  match = error_regex.match(html)
  full_error = match && match[1]
  full_error ? full_error.strip.split("\n").first : 'no selenium error found'
end

# return all text after "Failing Scenarios"
def output_synopsis(output_text, log_prefix)
  # example output:
  # ["    And I press \"resetButton\"                                                                                                                                    # step_definitions/steps.rb:63\n",
  #  "    Then element \"#runButton\" is visible                                                                                                                         # step_definitions/steps.rb:124\n",
  #  "    And element \"#resetButton\" is hidden                                                                                                                         # step_definitions/steps.rb:130\n",
  #  "\n",
  #  "Failing Scenarios:\n",
  #  "cucumber features/artist.feature:11 # Scenario: Loading the first level\n",
  #  "\n",
  #  "3 scenarios (1 failed, 2 skipped)\n",
  #  "41 steps (1 failed, 38 skipped, 2 passed)\n",
  #  "0m1.548s\n"]

  lines = output_text.lines

  failing_scenarios = lines.rindex("Failing Scenarios:\n")
  if failing_scenarios
    return lines[failing_scenarios..-1].map {|line| "#{log_prefix}#{line}"}.join
  else
    return lines.last(3).map {|line| "#{log_prefix}#{line}"}.join
  end
end

def html_output_filename(test_run_string, options)
  if options.html
    "#{LOCAL_LOG_DIRECTORY}/#{test_run_string}_output.html"
  end
end

def cucumber_arguments_for_feature(options, test_run_string, _)
  arguments = ''
  arguments += " --format html --out #{html_output_filename(test_run_string, options)}" if options.html
  arguments += ' -f pretty' if options.html # include the default (-f pretty) formatter so it does both

  # In CircleCI we export additional logs in junit xml format so CircleCI can
  # provide pretty test reports with success/fail/timing data upon completion.
  # See: https://circleci.com/docs/test-metadata/#cucumber
  if ENV['CI']
    arguments += " --format junit --out $CIRCLE_TEST_REPORTS/cucumber/#{test_run_string}.xml"
  end

  arguments
end

def run_feature(browser, feature, options)
  browser_name = browser_name_or_unknown(browser)
  test_run_string = test_run_identifier(browser, feature)
  log_prefix = "[#{feature.gsub(/.*features\//, '').gsub('.feature', '')}] "

  if options.browser && browser['browser'] && options.browser.casecmp(browser['browser']) != 0
    return
  end
  if options.os_version && browser['os_version'] && options.os_version.casecmp(browser['os_version']) != 0
    return
  end
  if options.browser_version && browser['browser_version'] && options.browser_version.casecmp(browser['browser_version']) != 0
    return
  end

  # Don't log individual tests because we hit ChatClient rate limits
  # ChatClient.log "Testing <b>dashboard</b> UI with <b>#{test_run_string}</b>..."
  puts "#{log_prefix}Starting UI tests for #{test_run_string}"

  run_environment = {}
  run_environment['BROWSER_CONFIG'] = browser_name

  run_environment['BS_ROTATABLE'] = browser['rotatable'] ? "true" : "false"
  run_environment['PEGASUS_TEST_DOMAIN'] = options.pegasus_domain if options.pegasus_domain
  run_environment['DASHBOARD_TEST_DOMAIN'] = options.dashboard_domain if options.dashboard_domain
  run_environment['HOUROFCODE_TEST_DOMAIN'] = options.hourofcode_domain if options.hourofcode_domain
  run_environment['CSEDWEEK_TEST_DOMAIN'] = options.csedweek_domain if options.csedweek_domain
  run_environment['TEST_LOCAL'] = options.local ? "true" : "false"
  run_environment['MAXIMIZE_LOCAL'] = options.maximize ? "true" : "false"
  run_environment['MOBILE'] = browser['mobile'] ? "true" : "false"
  run_environment['FAIL_FAST'] = options.fail_fast ? "true" : nil
  run_environment['TEST_RUN_NAME'] = test_run_string

  # disable some stuff to make require_rails_env run faster within cucumber.
  # These things won't be disabled in the dashboard instance we're testing against.
  run_environment['SKIP_I18N_INIT'] = 'true'
  run_environment['SKIP_DASHBOARD_ENABLE_PEGASUS'] = 'true'

  html_log = html_output_filename(test_run_string, options)

  arguments = ' -S' # strict mode, so that we fail on undefined steps
  arguments += cucumber_arguments_for_feature(options, test_run_string, 0)
  cucumber_succeeded, _, output_stdout, output_stderr, test_duration = run_tests(run_environment, feature, arguments, log_prefix)
  feature_succeeded = cucumber_succeeded

  $lock.synchronize do
    if feature_succeeded
      log_success prefix_string(Time.now, log_prefix)
      log_success prefix_string(browser.to_yaml, log_prefix)
      log_success prefix_string(output_stdout, log_prefix)
      log_success prefix_string(output_stderr, log_prefix)
    else
      log_error prefix_string(Time.now, log_prefix)
      log_error prefix_string(browser.to_yaml, log_prefix)
      log_error prefix_string(output_stdout, log_prefix)
      log_error prefix_string(output_stderr, log_prefix)
      log_browser_error prefix_string(browser.to_yaml, log_prefix)
    end
  end

  parsed_output = output_stdout.match(/^(?<scenarios>\d+) scenarios?( \((?<info>.*?)\))?/)
  scenario_count = nil
  unless parsed_output.nil?
    scenario_count = parsed_output[:scenarios].to_i
    scenario_info = parsed_output[:info]
    scenario_info = ", #{scenario_info}" unless scenario_info.blank?
  end

  if !parsed_output.nil? && scenario_count == 0 && feature_succeeded
    # Don't log individual skips because we hit ChatClient rate limits
    # ChatClient.log "<b>dashboard</b> UI tests skipped with <b>#{test_run_string}</b> (#{RakeUtils.format_duration(test_duration)}#{scenario_info})"
  elsif feature_succeeded
    # Don't log individual successes because we hit ChatClient rate limits
    # ChatClient.log "<b>dashboard</b> UI tests passed with <b>#{test_run_string}</b> (#{RakeUtils.format_duration(test_duration)}#{scenario_info})"
  else
    ChatClient.log "#{test_run_string} first selenium error: #{first_selenium_error(html_log)}" if options.html
    ChatClient.log output_synopsis(output_stdout, log_prefix), {wrap_with_tag: 'pre'} if options.output_synopsis
    ChatClient.log prefix_string(output_stderr, log_prefix), {wrap_with_tag: 'pre'}
    message = "#{log_prefix}<b>dashboard</b> UI tests failed with <b>#{test_run_string}</b> (#{RakeUtils.format_duration(test_duration)}#{scenario_info})"
    ChatClient.log message, color: 'red'
  end
  result_string =
    if scenario_count == 0
      'skipped'.blue
    elsif feature_succeeded
      'succeeded'.green
    else
      'failed'.red
    end
  puts prefix_string("UI tests for #{test_run_string} #{result_string} (#{RakeUtils.format_duration(test_duration)}#{scenario_info})", log_prefix)

  if scenario_count == 0 && !ENV['CI']
    skip_warning = "We didn't actually run any tests, did you mean to do this?\n".yellow
    skip_warning += <<EOS
Check the ~excluded @tags in the cucumber command line above and in the #{feature} file:
  - Do the feature or scenario tags exclude #{browser_name}?
EOS
    unless options.dashboard_db_access
      skip_warning += "  - Do you need to run this test on the test instance or against localhost (-l) for @dashboard_db_access?\n"
    end
    print skip_warning
  end

  [feature_succeeded, message, 0]
end

#
# This is the actual beginning of the script.
# Please keep this simple!
# Changes to the test procedure should live in main()
#
options = parse_options
status = main(options)
exit status
