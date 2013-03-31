# coding: utf-8

require 'logger'
require 'twitter'
require 'tweetstream'
require 'MeCab'
require 'mongo'
require 'daemons'
require './config'

module MarkovBot
  class MarkovDB
    def initialize
      @db = Mongo::Connection.new.db($env[:dbname])
    end

    def add(key1, key2, value)
      record = {:key1=>key1,:key2=>key2,:value=>value}
      @db.collection($env[:collname]).insert(record)
    end

    def find(key1,key2)
      res = @db.collection($env[:collname]).find({:key1=>key1,:key2=>key2},{:fields=>[:value]})
      res.each do |row|
        return row.inspect
      end
    end

    def build(key)
      return nil if find("",key) == nil
      text = key
      key1 = ""
      key2 = key
      while key2 != "__END__"
        key3 = find(key1,key2)
        text += key3
        key1 = key2
        key2 = key3
      end
      return text
    end
  end

  class Parser
    def initialize
      $mecab_opt = "-d " + $env[:mecab_dic_path] + " -O wakati "
      @mecab = MeCab::Tagger.new($mecab_opt)
    end

    def remove_mention(text)
      text.gsub(/@[a-zA-Z0-9_]{1,20}\ ?/,"")
    end

    def remove_rt_and_qt(text)
      text.gsub(/(RT|QT)\ @[a-zA-Z0-9_]{1,20}:\ ?/,"")
    end

    def remove_hashtag(text)
      text.gsub(/(#|＃)(\w|[Ａ-Ｚａ-ｚ０-９ぁ-んァ-ヴ一-龠])+\ ?/u,"")
    end

    def remove_url(text)
      text.gsub(/(https?|ftp)(:\/\/[-_.!~*\'()a-zA-Z0-9;\/?:@&=+$,%#]+)/,"")
    end

    def parse(text)
      @mecab.parse(text)
    end

    def parseToNode(text)
      @mecab.parseToNode(text)
    end
  end

  class Bot
    def initialize
      @logger = Logger.new($env[:logger_file]) if $env[:logger_file]

      @client = Twitter::Client.new
      @client.consumer_key = $env[:consumer_key]
      @client.consumer_secret = $env[:consumer_secret]
      @client.oauth_token = $env[:access_token]
      @client.oauth_token_secret = $env[:access_token_secret]
      @logger.debug("Gem Twitter Client instanciated.")

      @me = @client.verify_credentials({:skip_status=>true})
      @logger.debug("verify_credentials:"+@me.screen_name+"/"+@me.name)

      @stream = TweetStream::Client.new
      @stream.auth_method = :oauth
      @stream.consumer_key = $env[:consumer_key]
      @stream.consumer_secret = $env[:consumer_secret]
      @stream.oauth_token = $env[:access_token]
      @stream.oauth_token_secret = $env[:access_token_secret]
      @stream.on_timeline_status{|status| on_timeline_status(status)}
      @stream.on_direct_message{|direct_message| on_direct_message(direct_message)}
      @stream.on_event(:favorite){|event| on_favorite(event)}
      @stream.on_event(:unfavorite){|event| on_unfavorite(event)}
      @stream.on_event(:follow){|event| on_follow(event)}
      @stream.on_event(:unfollow){|event| on_unfollow(event)}
      @stream.on_event(:block){|event| on_block(event)}
      @stream.on_event(:unblock){|event| on_unblock(event)}
      @stream.on_delete{|status_id,user_id| on_delete(status_id, user_id)}
      @stream.on_limit{|skip_count| on_limit(skip_count)}
      @stream.on_reconnect{|timeout,retries| on_reconnect(timeout,retries)}
      @stream.on_error{|message| on_error(message)}
      @logger.debug("TweetStream Client instanciated.")

      @markov = MarkovDB.new
      @logger.debug("MarkovDB instanciated.")

      @parser = Parser.new
      @logger.debug("Parser instanciated.")
    end

    def run
      puts "run"
      @logger.debug("@stream.userstream begin")
      @stream.userstream
      @logger.debug("@stream.userstream end")
    end

    private
    def on_timeline_status(status)
      begin
        puts "timeline"
        @logger.debug("on_timeline_status")
        text = @parser.remove_rt_and_qt(status.text)
        text = @parser.remove_mention(text)
        text = @parser.remove_url(text)
        text = @parser.remove_hashtag(text)
        @logger.debug("Removed text:"+text)

        status_url = "https://twitter.com/"+status.user.screen_name
        status_url += "/status/"+status.id.to_s

        str = @parser.parse(text)

        if status.user_mentions.any? {|u| u.id == @me.id} then
          @logger.debug("Mentions to me")
          #@client.update(trim(status.user.name)+"さんからリプライきたよ")

          # Find noun
          node = @parser.parseToNode(text)
          word = nil
          while node = node.next
            @logger.debug("node:"+node.surface+","+node.feature)
            if node.feature =~ /^名詞/ then
              word = node.surface
              break
            end
          end
          reply = "@" + status.user.screen_name + " "
          #reply += word + "って名詞をみつけたよ" if word
          markov_str = @markov.build(word) if word
          reply += markov_str if markov_str
          @client.update(reply,{:in_reply_to_status_id=>status.id}) if markov_str
          return
        end

        if !(status.user == @me) then 
          key1 = ""
          node = @parser.parseToNode(text)
          key2 = "__BEGIN__"
          while key2 != "__END__" 
            node = node.next
            key3 = "__END__"
            key3 = node.surface if node.surface != ""
            @markov.add(key1,key2,key3)
            @logger.debug("add:"+key1+","+key2+","+key3)
            key1 = key2
            key2 = key3
          end
        end
      rescue => e
        @logger.error(e)
      end
    end

    def on_direct_message(direct_message)
      puts "on_direct_message"
    end

    def on_favorite(event)
      puts "favorite"
      @logger.debug("on_favorite")
      source_user = event[:source]
      target_user = event[:target]
      status = event[:target_object]
      status_url = "https://twitter.com/"+status.user.screen_name
      status_url += "/status/"+status.id.to_s
      @logger.debug(event)
      if target_user == @me then
        @client.update(source_user.name"さんにふぁぼられちゃった///")
      end
    end

    def on_unfavorite(event)
      puts "unfavorite"
      @logger.debug("on_favorite")
      source_user = event[:source]
      target_user = event[:target]
      status = event[:target_object]
      status_url = "https://twitter.com/"+status.user.screen_name
      status_url += "/status/"+status.id.to_s
      if target_user == @me then
        @client.update(source_user.name"さんにあんふぁぼされちゃった///")
      end
    end

    def on_follow(event)
      puts "follow"
      @logger.debug("on_follow")
      source_user = event[:source]
      target_user = event[:target]
      @logger.debug(source_user.name+" follows "+target_user.name)
    end

    def on_unfollow(event)
      puts "unfollow"
      @logger.debug("on_unfollow")
      target_user = event[:target]
      @logger.debug(@me.name+" unfollows "+target_user.name)
    end

    def on_block(event)
      puts "block"
      @logger.debug("on_block")
      target_user = event[:target]
      @logger.debug(@me.name+" blocks "+target_user.name)
    end

    def on_unblock(event)
      puts "unblock"
      @logger.debug("on_unblock")
      target_user = event[:target]
      @logger.debug(@me.name+" unblocks "+target_user.name)
    end

    def on_delete(status_id, user_id)
      puts "delete"
      @logger.debug("on_delete")
      #@client.update("ツイ消しを見たよ")
    end

    def on_user_update(event)
      puts("on_user_update")
      @logger.debug("on_user_update")
      @me = @client.verify_credentials({:skip_status=>true})
    end

    def on_limit(skip_count)
      puts "limit"
      @logger.debug("on_limit")
      @client.update("規制くらった")
    end

    def on_reconnect(timeout,retries)
      puts "reconnect"
    end

    def on_error(message)
      @logger.error(message)
    end

    def trim(name)
      name.gsub(/(\＠|\@)(.+)|\(.+\)/,"")
    end

    attr_accessor :logger, :client, :stream, :parser, :markov, :me
  end
end

options = {
  :dir_mode => :normal,
  :dir      => $env[:pid_dir],
  :multiple => false
}

#Daemons.daemonize(options)
#Daemons.run("markovbot.rb", options)
Daemons.run_proc($env[:app_name], options) do
  loop do
    @client = MarkovBot::Bot.new
    @client.run
  end
end

