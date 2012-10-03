require "language_pack"
require "language_pack/rails2"

# Rails 3 Language Pack. This is for all Rails 3.x apps.
class LanguagePack::Rails3 < LanguagePack::Rails2
  # detects if this is a Rails 3.x app
  # @return [Boolean] true if it's a Rails 3.x app
  def self.use?
    super &&
      File.exists?("config/application.rb") &&
      File.read("config/application.rb") =~ /Rails::Application/
  end

  def name
    "Ruby/Rails"
  end

  def default_process_types
    # let's special case thin here
    web_process = gem_is_bundled?("thin") ?
                    "bundle exec thin start -R config.ru -e $RAILS_ENV -p $PORT" :
                    "bundle exec rails server -p $PORT"

    super.merge({
      "web" => web_process,
      "console" => "bundle exec rails console"
    })
  end

private

  def plugins
    super.concat(%w( rails3_serve_static_assets )).uniq
  end

  # runs the tasks for the Rails 3.1 asset pipeline
  def run_assets_precompile_rake_task
    log("assets_precompile") do
      setup_database_url_env

      if rake_task_defined?("assets:precompile")
        topic("Preparing app for Rails asset pipeline")
        if File.exists?("public/assets/manifest.yml")
          puts "Detected manifest.yml, assuming assets were compiled locally"
        elsif precompiled_assets_are_cached?
          puts "Assets already compiled, loading from cache"
          cache_load "public/assets"
        else
          ENV["RAILS_GROUPS"] ||= "assets"
          ENV["RAILS_ENV"]    ||= "production"

          puts "Running: rake assets:precompile"
          require 'benchmark'
          time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }

          if $?.success?
            log "assets_precompile", :status => "success"
            puts "Asset precompilation completed (#{"%.2f" % time}s)"

            puts "Caching assets"
            cache_store "app/assets"
            cache_store "public/assets"

            if File.exist?("config/rackspace.yml")
              puts "Storing assets on on Rackspace"

              require 'net/http'
              require 'timeout'

              # Set up credentials
              # Sadly, it's easier to store them here than in ENV variables 
              # because they aren't easily/guaranteed to be available during the build process
              # (See: https://devcenter.heroku.com/articles/labs-user-env-compile)
              # But I'll probably re-work it to use the labs feature at some point. 
              # Legacy code, lone developer, you know the story.
              # 
              # Example config/rackspace.yml:
              #
              # credentials: &credentials
              #   username: example
              #   api_key: 3b8f726a48b88dbf55939a5951b49f65  
              #
              # development:
              #   <<: *credentials
              #   container: example_test
              #   cdn_url: http://c928372.r15.cf1.rackcdn.com
              #
              # test:
              #   <<: *credentials
              #   container: blp_test
              #   cdn_url: http://c928372.r15.cf1.rackcdn.com
              #
              # staging:
              #   <<: *credentials
              #   container: blp_staging
              #   cdn_url: https://c928372.ssl.cf1.rackcdn.com
              #
              # production:
              #   <<: *credentials
              #   container: example_production
              #   cdn_url: https://c928372.ssl.cf1.rackcdn.com

              username, api_key, container, cdn = YAML::load_file('config/rackspace.yml')['production'].values

              # Check for URL existence
              server = Net::HTTP.new(cdn, 443)

              # Once-per-session authorization
              _, destination, token = `
                curl -s -D - \
                  -H "X-Auth-Key: #{api_key}" \
                  -H "X-Auth-User: #{username}" \
                 https://auth.api.rackspacecloud.com/v1.0 | grep "X-"`.split("\n").map(&:strip).delete_if(&:empty?).map do |key|
                key.split(' ').last
              end

              # Upload each asset
              Dir.chdir('public') do
                Dir["**/*"].each do |file|
                  next if File.directory?(file)

                  # File already uploaded?
                  # We know this is the same because all assets have an md5 hash
                  Timeout::timeout(2) do
                    next if server.request_head(file).code == '200'
                  end rescue nil

                  puts "Storing #{file}..."

                  etag = `md5sum #{file}`.to_s.split(' ').first

                  `curl -s -X PUT -T #{file} \
                     -H "ETag: #{etag}" \
                     -H "X-Auth-Token: #{token}" \
                    #{destination}/#{container}/#{file}
                  `
                end
              end
            end
          else
            log "assets_precompile", :status => "failure"
            puts "Precompiling assets failed, enabling runtime asset compilation"
            install_plugin("rails31_enable_runtime_asset_compilation")
            puts "Please see this article for troubleshooting help:"
            puts "http://devcenter.heroku.com/articles/rails31_heroku_cedar#troubleshooting"
          end
        end
      end
    end
  end

  # setup the database url as an environment variable
  def setup_database_url_env
    ENV["DATABASE_URL"] ||= begin
      # need to use a dummy DATABASE_URL here, so rails can load the environment
      scheme =
        if gem_is_bundled?("pg")
          "postgres"
        elsif gem_is_bundled?("mysql")
          "mysql"
        elsif gem_is_bundled?("mysql2")
          "mysql2"
        elsif gem_is_bundled?("sqlite3") || gem_is_bundled?("sqlite3-ruby")
          "sqlite3"
        end
      "#{scheme}://user:pass@127.0.0.1/dbname"
    end
  end

  # have the assets changed since we last pre-compiled them?
  def precompiled_assets_are_cached?
    run("diff app/assets #{cache_base + 'app/assets'} --recursive").split("\n").length.zero?
  end
end
