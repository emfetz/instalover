require 'net/http'
require 'addressable/uri'
require 'uri'

class Message

  TROPO_URL = "http://api.tropo.com/1.0"
  MESSAGE_TOKEN = "aeea3bf2048d1848bc4e706ff76bfe98951f433968b934a2a1d80cf1e047ba36c91a2cd53a958e15319a564a"
  DATING_START_STRING = '5PM EDT'
  DATING_END_STRING = '10:59PM EDT'
  DATING_START = Time.zone.parse(DATING_START_STRING)
  DATING_END = Time.zone.parse(DATING_END_STRING)
  HANGUP_RESPONSE = '{"tropo": [{"hangup": null}]}'

  def self.deliver(to, message, deliver_in_development = false)
    if Rails.env.development? && !deliver_in_development
      raise "Tried to deliver an SMS in development without passing deliver_in_development = true."
    end

    Rails.logger.info "Enqueued SMS: TO: #{to}: #{message}"

    params = Addressable::URI.new
    params.query_values = {
      "relay" => "relay",
      "to" => to,
      "message" => message,
      "token" => MESSAGE_TOKEN,
      "action" =>"create"
    }
    param_string = params.query

    QUEUE.enqueue(MessageSender, "#{TROPO_URL}/sessions?#{param_string}")
  end

  ### TODO: untested
  def self.json_for_relay(message_params)
    to = message_params[:to]
    message = message_params[:message]

    tropo = Tropo::Generator.new do
      message({
        :to => 'tel:+' + to,
        :channel => 'TEXT',
        :network => 'SMS'
      }) do
        say :value => message
      end
    end

    tropo.response
  end

  def self.handle_incoming(phone_number, message_text)
    Rails.logger.info("SMS INCOMING: FROM #{phone_number}: #{message_text}")

    user = User.find_by_phone_number(phone_number)

    if user.nil?
      Message.deliver(phone_number,
                      "Sorry, you must register first at instalover.com")
      return
    end

    if user.unconfirmed?
      user.deliver_secret_code
      return
    end

    if user.dflns.unwritten.any?
      handle_dfln(user, message_text)
      return
    end

    if message_text =~ /^\s*#{COMMANDS[:new_date].gsub(' ','.*')}/i
      handle_new_date(user)
    elsif message_text =~ /^\s*#{COMMANDS[:ok].gsub(' ','.*')}/i
      handle_ok(user)
    elsif message_text =~ /^\s*#{COMMANDS[:skeeze].gsub(' ','.*')}/i
      handle_ok(user, :skeeze => true)
    elsif message_text =~ /^\s*#{COMMANDS[:accept].gsub(' ','.*')}/i
      handle_accept(user)
    elsif message_text =~ /^\s*#{COMMANDS[:sext].gsub(' ','.*')}\s*(.*)/i
      handle_texting_proxy(user, $1)
    elsif message_text =~ /^\s*#{COMMANDS[:quit].gsub(' ','.*')}/i
      handle_safeword(user)
    elsif message_text =~ /^\s*#{COMMANDS[:retry].gsub(' ','.*')}/i
      handle_retry(user)
    elsif message_text =~ /^\s*#{COMMANDS[:women_only].gsub(' ','.*')}/i
      handle_new_date(user, :desires_male => false, :desires_female => true, :desires_other => false)
    elsif message_text =~ /^\s*#{COMMANDS[:men_only].gsub(' ','.*')}/i
      handle_new_date(user, :desires_male => true, :desires_female => false, :desires_other => false)
    elsif message_text =~ /^\s*#{COMMANDS[:other_only].gsub(' ','.*')}/i
      handle_new_date(user, :desires_male => false, :desires_female => false, :desires_other => true)
    elsif message_text =~ /^\s*#{COMMANDS[:anything].gsub(' ','.*')}/i
      handle_new_date(user, :desires_male => true, :desires_female => true, :desires_other => true)
    else
      handle_unknown(user)
    end
  end

  def self.handle_texting_proxy(user, message)
    if dating_user = user.date
      user.date.tell("#{user.name} says: #{message}")
    else
      user.tell("You have no date for us to share that with. Reply with '#{COMMANDS[:new_date]}'.")
    end
  end

  def self.handle_new_date(user, meetup_restrictions = {})
    if within_dating_hours?
      user.founded_meetups.proposed.destroy_all

      if user.founded_meetups.unscheduled.any?
        user.tell("Whoa there, pardner - we're looking for someone right now.  If nobody shows after 5 minutes, then you can ask again.")
      else
        user.offers.cancel_all

        meetup = Meetup.create(
          meetup_restrictions.merge(
            :first_user => user,
            :description => DateSuggestion.next_place_and_time)
        )


        user.tell("Should we find you a date at #{meetup.description}? Reply 'ok' or 'new date' to try again.")
        QUEUE.enqueue_at(5.minutes.from_now, OkTimeoutMessageDelayer, :user_id => user.id)
      end
    else
      outside_dating_hours(user)
    end
  end

  def self.handle_retry(user)
    if within_dating_hours?
      if meetup = user.founded_meetups.retryable.last
        meetup.unschedule!
        user.matching_for_meetup(meetup).first(5).each do |matching_user|
          Offer.create(:offered_user => matching_user, :meetup => meetup)
        end
        QUEUE.enqueue_at(5.minutes.from_now, RejectMessageDelayer, :user_id => user.id)
        user.tell("Trying to get you a date. Back in five.")
      else
        handle_new_date(user)
      end
    else
      ### TODO: untested
      outside_dating_hours(user)
    end
  end

  def self.within_dating_hours?
    now = Time.zone.now
    now.hour >= DATING_START.hour &&
      now.hour <= DATING_END.hour
  end

  def self.outside_dating_hours(user)
    user.tell("Outside of the dating hours: #{DATING_START_STRING} to #{DATING_END_STRING}. Please try again then!")
  end

  def self.handle_ok(user, meetup_restrictions = {})
    meetup = user.founded_meetups.proposed.first
    if meetup
      meetup.unschedule!
      if meetup_restrictions[:skeeze]
        matches = user.skeeze_matching_for_meetup(meetup).first(5)
      else
        matches = user.matching_for_meetup(meetup).first(5)
      end
      matches.each do |matching_user|
        Offer.create(:offered_user => matching_user, :meetup => meetup)
      end
      QUEUE.enqueue_at(5.minutes.from_now, RejectMessageDelayer, :user_id => user.id)
    else
      handle_unknown(user)
    end
  end

  def self.handle_skeeze(user)
    meetup = user.founded_meetups.proposed.first
    if meetup
      meetup.unschedule!
      user.skeeze_matching_for_meetup(meetup).first(5).each do |matching_user|
        Offer.create(:offered_user => matching_user, :meetup => meetup)
      end
      QUEUE.enqueue_at(5.minutes.from_now, RejectMessageDelayer, :user_id => user.id)
    else
      handle_unknown(user)
    end
  end

  def self.handle_unknown(user)
      user.tell("Sorry, I don't know what to do with that. You can text '#{COMMANDS[:new_date]}' to get a date. To stop receiving texts, please text '#{COMMANDS[:quit]}'")

  end

  def self.handle_accept(user)
    if accepted_offer = user.latest_offer
      accept_offer(accepted_offer)

      meetup = accepted_offer.meetup
      meetup.pending_offers.each do |offer|
        offer.offered_user.tell("Too slow! Would you like to get a date? Reply '#{COMMANDS[:new_date]}'.")
        offer.decline!
      end
    else
      user.tell("You don't have any date offers to accept")
    end
  end

  def self.accept_offer(offer)
    offer.schedule_meetup!
    deliver_date(offer.offered_user, offer.meetup.first_user)
    deliver_date(offer.meetup.first_user, offer.meetup.second_user)
    offer.accept!
  end

  def self.deliver_date(first_user, second_user)
    first_user.tell(%{Nice! You've got a date with #{second_user.name}. Describe yourself using '#{COMMANDS[:sext]}' followed by a message.})
  end

  def self.handle_safeword(user)
    user.tell("I got it - 'no' means no!  We could just be friends, but we're not fooling anyone.  You're unsubscribed - have a nice life!")
    user.destroy
  end

  def self.handle_dfln(user, message)
    dfln = user.dflns.unwritten.last
    dfln.update_attributes({
      :text => message
    })
  end

  def self.handle_no_responses(user)
    meetup = user.founded_meetups.unscheduled.first
    if !meetup.nil?
      user.tell("We called every number in our little black book, but only got answering machines. Try again with '#{COMMANDS[:retry]}'.")
      meetup.offers.pending.each do |offer|
        offer.offered_user.tell("Too slow! Would you like to get a date? Reply '#{COMMANDS[:new_date]}'.")
        offer.cancel!
      end
      meetup.retryable!
    end
  end

  def self.handle_ok_timeout(user)
    meetup = user.founded_meetups.proposed.first
    if !meetup.nil?
      user.tell("I guess you don't want to go on a date... Text '#{COMMANDS[:new_date]}' again when you change your mind")
      meetup.state = "cancelled"
      meetup.save
    end
  end
end
