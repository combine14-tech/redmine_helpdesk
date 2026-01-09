module RedmineHelpdesk
  module MailHandlerPatch
    def self.included(base) # :nodoc:
      base.send(:include, InstanceMethods)

      base.class_eval do
        alias_method :dispatch_to_default_without_helpdesk, :dispatch_to_default
        alias_method :dispatch_to_default, :dispatch_to_default_with_helpdesk
        # needed for reopening a closed issue
        alias_method :receive_issue_reply_without_helpdesk, :receive_issue_reply
        alias_method :receive_issue_reply, :receive_issue_reply_with_helpdesk
      end
    end

    module InstanceMethods
      private
      # Overrides the dispatch_to_default method to
      # set the owner-email of a new issue created by
      # an email request
      def dispatch_to_default_with_helpdesk
        issue = receive_issue
        issue.reload # prevent ActiveRecord::StaleObjectError
        roles = if issue.author.class == AnonymousUser
          Role.where(builtin: issue.author.id)
        else
          issue.author.roles_for_project(issue.project)
        end
        # add owner-email only if the author has assigned some role with
        # permission treat_user_as_supportclient enabled
        if issue.author.type.eql?("AnonymousUser") || roles.any? {|role| role.allowed_to?(:treat_user_as_supportclient) }
          sender_email = @email.from.first
          
          # any cc handling needed?
          custom_value = custom_field_value(issue.project,'cc-handling')
#          if (!@email.cc.nil?) && (custom_value.value == '1')
#            carbon_copy = @email[:cc].formatted.join(', ')
#            custom_value = custom_field_value(issue,'copy-to')
#            custom_value.value = carbon_copy
#            custom_value.save( validate: false ) # skip validation!
	  if custom_value.value == '1'
	  # Collect all recipients from CC and TO
	  all_recipients = collect_all_copy_recipients(sender_email)
	  	if all_recipients.any?
		    custom_value = custom_field_value(issue,'copy-to')
		    custom_value.value = all_recipients.join(', ')
		    custom_value.save( validate: false )
		    carbon_copy = all_recipients.join(', ')
		else
		    carbon_copy = nil
		end
          else
            carbon_copy = nil
          end
          



	from_addr = Array(@email.from_addrs).first

	# 1. E-mail отправителя
	sender_email =
	  if from_addr.is_a?(Mail::Address)
    	    from_addr.address
  	  else
    	    # from_addrs вернул строки — берём первый из @email.from
    	    Array(@email.from).first.to_s
  	end

	# 2. Имя отправителя
	sender_name =
  	  if from_addr.respond_to?(:display_name) && from_addr.display_name.present?
    	    from_addr.display_name
  	  else
    	    # Имени нет — делаем его из e-mail'а
    	    sender_email.split('@').first.split(/[._-]/).map(&:capitalize).join(' ')
  	end

	# 3. Строка "От:"
	author_line = "**От:** #{sender_name} <#{sender_email}>\n\n"

	issue.description = (author_line + email_details.to_s + issue.description.to_s)


	  issue.save( validate: false ) # skip validation!
          
          custom_value = custom_field_value(issue,'owner-email')
          if custom_value.value.to_s.strip.empty?
            custom_value.value = sender_email
            custom_value.save( validate: false ) # skip validation!
          else
            # Email owner field was already set by some preprocess hooks.
            # So now we need to send message to another recepient.
            sender_email = custom_value.value.to_s.strip
          end
          
          # regular email sending to known users is done
          # on the first issue.save. So we need to send
          # the notification email to the supportclient
          # on our own.
        mail = HelpdeskMailer.email_to_supportclient(
          issue, {
  	    recipient:   sender_email,
    	    carbon_copy: carbon_copy
	  }
	)
	mail.deliver if mail	

        end
        after_dispatch_to_default_hook issue
        return issue
      end

      # let other plugins the chance to override this
      # method to hook into dispatch_to_default
      def after_dispatch_to_default_hook(issue)
      end

      # Fix an issue with email.has_attachments?
      def add_attachments(obj)
         if !email.attachments.nil? && email.attachments.size > 0
           email.attachments.each do |attachment|
             obj.attachments << Attachment.create(
               container:    obj,
               file:         attachment.decoded,
               filename:     attachment.filename,
               author:       user,
               content_type: attachment.mime_type
             )
          end
        end
      end

      # Overrides the receive_issue_reply method
      def receive_issue_reply_with_helpdesk(issue_id, from_journal=nil)
        issue = Issue.find_by_id(issue_id)
        return unless issue

        # reopening a closed issues by email
        custom_value = custom_field_value(issue.project,'reopen-issues-with')
        if issue.closed? && custom_value.present? && custom_value.value.present?
          status_id = IssueStatus.where("name = ?", custom_value.value).try(:first).try(:id)
          unless status_id.nil?
            issue.status_id = status_id
            issue.save
          end
        end

        # call original method
        receive_issue_reply_without_helpdesk(issue_id, from_journal)

        # store email-details before each note
        last_journal = Journal.find(issue.last_journal_id)
        last_journal.notes = email_details + last_journal.notes
        last_journal.save

        return last_journal
      end
      
      def custom_field_value(issue,name)
        custom_field = CustomField.find_by_name(name)
        CustomValue.where(
          "customized_id = ? AND custom_field_id = ?", issue.id, custom_field.id
        ).first
      end

      def email_details
        details =  "From: " + @email[:from].formatted.first + "\n"
        details << "To:   " + @email[:to].formatted.join(', ') + "\n" if !@email.to.nil?
        details << "Cc:   " + @email[:cc].formatted.join(', ') + "\n" if !@email.cc.nil?
        details << "Date: " + @email[:date].to_s + "\n"
        details << "Subject: " + @email.subject.to_s + "\n" if @email.subject.present?
	"<pre>\n" + Mail::Encodings.unquote_and_convert_to(details, 'utf-8') + "</pre>\n\n"
      end

private

def collect_all_copy_recipients(sender_email)
  recipients = []
  
  # Add CC recipients
  if @email.cc.present?
    cc_addresses = @email[:cc].formatted rescue @email.cc
    recipients += Array(cc_addresses)
  end
  
  # Add additional TO recipients
  if @email.to.present?
    begin
      all_to_addresses = @email[:to].formatted rescue @email.to
      
      # Define service emails (все адреса вашей техподдержки)
      service_emails = [
        'sender-redmine@consultant.ru',
        'network@consultant.ru'
      ]
      
      # Build exclusion list
      excluded_emails = (
        [sender_email, Setting.mail_from.to_s] + service_emails
      ).compact.map(&:strip).map(&:downcase).uniq
      
      Rails.logger.debug "Helpdesk: Excluded emails: #{excluded_emails.inspect}"
      
      # Filter TO addresses
      additional_to = Array(all_to_addresses).reject do |addr|
        email_only = addr.match(/<(.+?)>/)&.[](1) || addr
        email_only = email_only.strip.downcase
        
        is_excluded = excluded_emails.include?(email_only)
        Rails.logger.debug "  Checking #{email_only}: #{is_excluded ? 'EXCLUDED' : 'INCLUDED'}"
        
        is_excluded
      end
      
      recipients += additional_to
      Rails.logger.info "Helpdesk: Added #{additional_to.size} TO recipients to copy-to"
    rescue => e
      Rails.logger.error "Helpdesk: Error processing TO addresses: #{e.message}"
    end
  end
  
  # Cleanup and deduplicate
  result = recipients.uniq.compact.reject(&:blank?)
  Rails.logger.info "Helpdesk: Final copy-to list (#{result.size} recipients): #{result.inspect}"
  
  result
end


    end # module InstanceMethods
  end # module MailHandlerPatch
end # module RedmineHelpdesk

# Add module to MailHandler class
MailHandler.send(:include, ::RedmineHelpdesk::MailHandlerPatch)
