# encoding: utf-8
require "sinatra"
require "json"
require "httparty"
require "date"
require "redis"
require "dotenv"
require "oauth"

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  # Exclude messages that match this regex
  set :ignore_regex, Regexp.new(ENV["IGNORE_REGEX"], "i")
  # Respond to messages that match this
  set :reply_regex, Regexp.new(ENV["REPLY_REGEX"], "i")
  # Mute if this message is received
  set :mute_regex, Regexp.new(ENV["MUTE_REGEX"], "i")
  
  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV["LOCAL_REDIS_URL"])
  when :production
    uri = URI.parse(ENV["REDISCLOUD_URL"])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

get "/" do
  "hi."
end

get "/markov" do
  if params[:token] == ENV["OUTGOING_WEBHOOK_TOKEN"]
    count = params[:count].nil? ? 1 : [params[:count].to_i, 100].min
    body = []
    count.times do
      body << build_markov
    end
    status 200
    headers "Access-Control-Allow-Origin" => "*"
    body body.join("\n")
  else
    status 403
    body "Nope."
  end
end

get "/form" do
  if params[:token] == ENV["OUTGOING_WEBHOOK_TOKEN"]
    status 200
    erb :form
  else
    status 403
    body "Nope."
  end
end

post "/markov" do
  begin
    response = ""
    if params[:token] == ENV["OUTGOING_WEBHOOK_TOKEN"] &&
       params[:user_id] != "USLACKBOT" &&
       !params[:text].nil? &&
       params[:text].match(settings.mute_regex)
      time = params[:text].scan(/\d+/).first.nil? ? 60 : params[:text].scan(/\d+/).first.to_i
      reply = shut_up(time)
      response = json_response_for_slack(reply)
    end

    # Ignore if text is a cfbot command, or a bot response, or the outgoing integration token doesn't match
    unless params[:text].nil? ||
           params[:text].match(settings.ignore_regex) ||
           params[:user_name] && params[:user_name].match(settings.ignore_regex) ||
           params[:user_id] == "USLACKBOT" ||
           params[:user_id] == "" ||
           params[:token] != ENV["OUTGOING_WEBHOOK_TOKEN"]

      # Store the text if someone is not manually invoking a reply
      # and if the selected user is defined and matches
      if !ENV["SLACK_USER"].nil?
        if !params[:text].match(settings.reply_regex) && (ENV["SLACK_USER"] == params[:user_name] || ENV["SLACK_USER"] == params[:user_id])
          $redis.pipelined do
            store_markov(params[:text])
          end
        end
      else
        if !params[:text].match(settings.reply_regex)
          $redis.pipelined do
            store_markov(params[:text])
          end
        end
      end

      # Reply if the bot isn't shushed AND either the random number is under the threshold OR the bot was invoked
      if !$redis.exists("snarkov:shush") &&
         params[:user_id] != "WEBFORM" &&
         (rand <= ENV["RESPONSE_CHANCE"].to_f || params[:text].match(settings.reply_regex))
        reply = build_markov
        response = json_response_for_slack(reply)
        tweet(reply) unless ENV["SEND_TWEETS"].nil? || ENV["SEND_TWEETS"].downcase == "false"
      end
    end
  rescue => e
    puts "[ERROR] #{e}"
    puts e.backtrace.join("\n")
    response = ""
  end
  
  status 200
  body response
end

def store_markov(text)
  # Split long text into sentences
  sentences = text.split(/\.\s+|\n+/)
  sentences.each do |t|
    # Horrible regex, this
    text = t.gsub(/<@([\w]+)>:?/){ |m| get_slack_name($1) }
            .gsub(/<#([\w]+)>/){ |m| get_channel_name($1) }
            .gsub(/<.*?>:?/, "")
            .gsub(/:-?\(/, ":disappointed:")
            .gsub(/:-?\)/, ":smiley:")
            .gsub(/;-?\)/, ":wink:")
            .gsub(/[‘’]/,"\'")
            .gsub(/\s_|_\s|_[,\.\?!]|^_|_$/, " ")
            .gsub(/\s\(|\)\s|\)[,\.\?!]|^\(|\)$/, " ")
            .gsub(/&lt;.*?&gt;|&lt;|&gt;|[\*`<>"“”•]/, "")
            .downcase
            .strip
    # Split words into array
    words = text.split(/\s+/)
    # Ignore if phrase is less than 3 words
    unless words.size < 3
      puts "[LOG] Storing: #{text}"
      (words.size - 2).times do |i|
        # Join the first two words as the key
        key = words[i..i+1].join(" ")
        # And the third as a value
        value = words[i+2]
        # If it's the first pair of words, store in special set
        $redis.sadd("snarkov:initial_words", key) if i == 0
        $redis.sadd(key, value)
      end
    end
  end
end

def build_markov
  phrase = []
  # Get a random pair of words from Redis
  initial_words = $redis.srandmember("snarkov:initial_words")

  unless initial_words.nil?
    # Split the key into the two words and add them to the phrase array
    initial_words = initial_words.split(" ")
    first_word = initial_words.first
    second_word = initial_words.last
    phrase << first_word
    phrase << second_word

    # With these two words as a key, get a third word from Redis
    # until there are no more words
    while phrase.size <= ENV["MAX_WORDS"].to_i && new_word = get_next_word(first_word, second_word)
      # Add the new word to the array
      phrase << new_word
      # Set the second word and the new word as keys for the next iteration
      first_word, second_word = second_word, new_word
    end
  end
  phrase.join(" ").strip
end

def get_next_word(first_word, second_word)
  $redis.srandmember("#{first_word} #{second_word}")
end

def shut_up(minutes = 60)
  minutes = [minutes, 60*24].min
  if minutes > 0
    $redis.setex("snarkov:shush", minutes * 60, "true")
    puts "[LOG] Shutting up: #{minutes} minutes"
    if minutes == 1
      "ok, i'll shut up for #{minutes} minute"
    else
      "ok, i'll shut up for #{minutes} minutes"
    end
  end
end

def json_response_for_slack(reply)
  puts "[LOG] Replying: #{reply}"
  response = { text: reply, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  response.to_json
end

def tweet(tweet_text)
  begin
    consumer = OAuth::Consumer.new(ENV["TWITTER_API_KEY"], ENV["TWITTER_API_SECRET"], { site: "http://api.twitter.com" })
    access_token = OAuth::AccessToken.new(consumer, ENV["TWITTER_TOKEN"], ENV["TWITTER_TOKEN_SECRET"])
    tweet_text = tweet_text[0..138] + "…" if tweet_text.size > 140
    response = access_token.post("https://api.twitter.com/1.1/statuses/update.json", { status: tweet_text })
    response_json = JSON.parse(response.body)
    puts "[LOG] Sent tweet: http://twitter.com/statuses/#{response_json["id"]}"
  rescue OAuth::Error
    nil
  end
end

def get_slack_name(slack_id)
  username = ""
  uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    user = response["members"].find { |u| u["id"] == slack_id }
    unless user.nil?
      if !user["profile"].nil? && !user["profile"]["first_name"].nil?
        username = user["profile"]["first_name"]
      else
        username = user["name"]
      end
    end

  else
    puts "Error fetching user: #{response["error"]}" unless response["error"].nil?
  end
  username
end

def get_slack_user_id(username)
  user_id = nil
  uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    user = response["members"].find { |u| u["name"] == username.downcase }
    user_id = "#{user["id"]}" unless user.nil?
  else
    puts "Error fetching user ID: #{response["error"]}" unless response["error"].nil?
  end
  user_id
end

def get_channel_id(channel_name)
  uri = "https://slack.com/api/channels.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    channel = response["channels"].find { |u| u["name"] == channel_name.gsub("#","") }
    channel_id = channel["id"] unless channel.nil?
  else
    puts "Error fetching channel id: #{response["error"]}" unless response["error"].nil?
    channel_id = ""
  end
  channel_id
end

def get_channel_name(channel_id)
  channel_name = ""
  uri = "https://slack.com/api/channels.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    channel = response["channels"].find { |u| u["id"] == channel_id }
    channel_name = "##{channel["name"]}" unless channel.nil?
  else
    puts "Error fetching channel name: #{response["error"]}" unless response["error"].nil?
  end
  channel_name
end

def import_history(channel_id, latest = nil, user_id = nil, oldest = nil)
  uri = "https://slack.com/api/channels.history?token=#{ENV["API_TOKEN"]}&channel=#{channel_id}&count=1000"
  uri += "&latest=#{latest}" unless latest.nil?
  uri += "&oldest=#{oldest}" unless oldest.nil?
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    # Find all messages that are plain messages (no subtype), are not hidden, are not from a bot (integrations, etc.) and are not cfbot commands
    messages = response["messages"].find_all{ |m| m["subtype"].nil? && m["hidden"] != true && m["bot_id"].nil? && !m["user"].nil? && !m["text"].match(settings.reply_regex) && !m["text"].match(settings.ignore_regex) }
    # Filter by user id, if necessary
    messages = messages.find_all{ |m| m["user"] == user_id } unless user_id.nil?

    if messages.size > 0
      puts "Importing #{messages.size} messages from #{DateTime.strptime(messages.first["ts"],"%s").strftime("%c")}" if messages.size > 0  
      $redis.pipelined do
        messages.each do |m|
          store_markov(m["text"])
        end
      end
    end

    # If there are more messages in the API call, make another call, starting with the timestamp of the last message
    if response["has_more"] && !response["messages"].last["ts"].nil?
      latest = response["messages"].last["ts"]
      import_history(channel_id, latest, user_id, oldest)
    end
  else
    puts "Error fetching channel history: #{response["error"]}" unless response["error"].nil?
  end
end
