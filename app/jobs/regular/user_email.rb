require_dependency 'email/sender'

module Jobs

  # Asynchronously send an email to a user
  class UserEmail < Jobs::Base

    def execute(args)
      notification, post = nil

      raise Discourse::InvalidParameters.new(:user_id) unless args[:user_id].present?
      raise Discourse::InvalidParameters.new(:type)    unless args[:type].present?

      type = args[:type]

      user = User.find_by(id: args[:user_id])

      set_skip_context(type, args[:user_id], args[:to_address].presence || user.try(:email).presence || "no_email_found")
      return skip(I18n.t("email_log.no_user", user_id: args[:user_id])) unless user

      if args[:post_id]
        post = Post.find_by(id: args[:post_id])
        return skip(I18n.t('email_log.post_not_found', post_id: args[:post_id])) unless post.present?
      end

      if args[:notification_id].present?
        notification = Notification.find_by(id: args[:notification_id])
      end

      message, skip_reason = message_for_email( user,
                                   post,
                                   type,
                                   notification,
                                   args[:notification_type],
                                   args[:notification_data_hash],
                                   args[:email_token],
                                   args[:to_address] )


      if message
        Email::Sender.new(message, args[:type], user).send
      else
        skip_reason
      end
    end

    def set_skip_context(type, user_id, to_address)
      @skip_context = { type: type, user_id: user_id, to_address: to_address }
    end

    NOTIFICATIONS_SENT_BY_MAILING_LIST ||= Set.new [
      Notification.types[:posted],
      Notification.types[:replied],
      Notification.types[:mentioned],
      Notification.types[:group_mentioned],
      Notification.types[:quoted],
    ]

   def message_for_email(user, post, type, notification,
                          notification_type=nil, notification_data_hash=nil,
                          email_token=nil, to_address=nil)

      set_skip_context(type, user.id, to_address || user.email)

      return skip_message(I18n.t("email_log.anonymous_user"))   if user.anonymous?
      return skip_message(I18n.t("email_log.suspended_not_pm")) if user.suspended? && type != :user_private_message

      return if user.staged && type == :digest

      seen_recently = (user.last_seen_at.present? && user.last_seen_at > SiteSetting.email_time_window_mins.minutes.ago)
      seen_recently = false if user.email_always || user.staged

      email_args = {}

      if post || notification || notification_type
        return skip_message(I18n.t('email_log.seen_recently')) if seen_recently && !user.suspended?
      end

      if post
        email_args[:post] = post
      end

      if notification || notification_type
        email_args[:notification_type] ||= notification_type || notification.try(:notification_type)
        email_args[:notification_data_hash] ||= notification_data_hash || notification.try(:data_hash)

        if user.mailing_list_mode? &&
           !post.topic.private_message? &&
           NOTIFICATIONS_SENT_BY_MAILING_LIST.include?(email_args[:notification_type])
           # no need to log a reason when the mail was already sent via the mailing list job
           return [nil, nil]
        end

        unless user.email_always?
          if (notification && notification.read?) || (post && post.seen?(user))
            return skip_message(I18n.t('email_log.notification_already_read'))
          end
        end
      end

      skip_reason = skip_email_for_post(post, user)
      return skip_message(skip_reason) if skip_reason

      # Make sure that mailer exists
      raise Discourse::InvalidParameters.new("type=#{type}") unless UserNotifications.respond_to?(type)

      if email_token.present?
        email_args[:email_token] = email_token
      end

      message = UserNotifications.send(type, user, email_args)

      # Update the to address if we have a custom one
      if message && to_address.present?
        message.to = [to_address]
      end

      [message, nil]
    end

    private

    def skip_message(reason)
      [nil, skip(reason)]
    end

    # If this email has a related post, don't send an email if it's been deleted or seen recently.
    def skip_email_for_post(post, user)
      if post
        return I18n.t('email_log.topic_nil')      if post.topic.blank?
        return I18n.t('email_log.post_deleted')   if post.user_deleted?
        return I18n.t('email_log.user_suspended') if (user.suspended? && !post.user.try(:staff?))
        return I18n.t('email_log.already_read')   if PostTiming.where(topic_id: post.topic_id, post_number: post.post_number, user_id: user.id).present?
      else
        false
      end
    end

    def skip(reason)
      EmailLog.create!(
        email_type: @skip_context[:type],
        to_address: @skip_context[:to_address],
        user_id: @skip_context[:user_id],
        skipped: true,
        skipped_reason: reason,
      )
    end

  end

end
