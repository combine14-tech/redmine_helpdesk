#
# With Rails 3 mail is send with the mail method. Sadly redmine
# uses this method-name too in their mailer. This is the reason
# why we need our own Mailer class.
#
class HelpdeskMailer < ActionMailer::Base
  helper :application

  include Redmine::I18n
  include MacroExpander

  # set the hostname for url_for helper
  def self.default_url_options
    { :host => Setting.host_name, :protocol => Setting.protocol }
  end

  # Sending email notifications to the supportclient
  def email_to_supportclient(issue, params)
    # issue, recipient, journal=nil, text='', copy_to=nil

    recipient = params[:recipient]
    journal = params[:journal]
    text = params[:text]
    carbon_copy = params[:carbon_copy]

    if journal.nil? && text.to_s.strip.empty?
      Rails.logger.info "HelpdeskMailer: skip first auto-reply for issue ##{issue.id}"
      return nil
    end

    redmine_headers 'Project' => issue.project.identifier,
                    'Issue-Id' => issue.id,
                    'Issue-Author' => issue.author.login
    redmine_headers 'Issue-Assignee' => issue.assigned_to.login if issue.assigned_to
    message_id issue
    references issue

    subject = "[#{issue.project.name} - ##{issue.id}] #{issue.subject}"

    # Set 'from' email-address to 'helpdesk-sender-email' if available.
    # Falls back to regular redmine behaviour if 'sender' is empty.
    p = issue.project
    s = CustomField.find_by_name('helpdesk-sender-email')
    sender = p.custom_value_for(s).try(:value) if p.present? && s.present?

    # If a custom field with text for the first reply is
    # available then use this one instead of the regular
    r = CustomField.find_by_name('helpdesk-first-reply')
    f = CustomField.find_by_name('helpdesk-email-footer')
    reply  = p.nil? || r.nil? ? '' : p.custom_value_for(r).try(:value)
    footer = p.nil? || f.nil? ? '' : p.custom_value_for(f).try(:value)

    # add carbon copy
    ct = CustomField.find_by_name('copy-to')
    if carbon_copy.nil?
      carbon_copy = issue.custom_value_for(ct).try(:value)
    end

    # add any attachments
    if journal.present? && text.present?
      journal.details.each do |d|
        if d.property == 'attachment'
          a = Attachment.find(d.prop_key)
          begin
            attachments[a.filename] = File.binread(a.diskfile)
          rescue
            # ignore rescue
          end
        end
      end
    end

    if @message_id_object
      headers[:message_id] = "<#{self.class.message_id_for(@message_id_object)}>"
    end
    if @references_objects
      headers[:references] = @references_objects.collect { |o| "<#{self.class.references_for(o)}>" }.join(' ')
    end

    # create mail object to deliver
    mail = if text.present? || reply.present?
      # sending out the journal note to the support client
      # or the first reply message

      t = text.present? ? "#{text}\n\n#{footer}" : reply
      body = expand_macros(t, issue, journal)

      # ---- История переписки: описание + все предыдущие публичные комментарии ----
      if journal.present?
        history_entries = []

        # 1) Первое письмо (описание задачи)
        if issue.description.present?
          ticket = helpdesk_ticket_for(issue)

          customer_email =
            (ticket && (ticket.respond_to?(:customer_email) ? ticket.customer_email : nil)).presence ||
            recipient.to_s
          customer_email = extract_email(customer_email)

          ticket_name =
            (ticket && (ticket.respond_to?(:customer_name) ? ticket.customer_name : nil)).presence ||
            (ticket && (ticket.respond_to?(:name) ? ticket.name : nil)).presence

          # ВАЖНО: приоритет имени из Redmine по email, затем ticket
          customer_name = redmine_user_name_by_email(customer_email).presence || ticket_name

          author_str = customer_name.present? ? "#{customer_name} <#{customer_email}>" : customer_email

          history_entries << {
            seq: 0, # описание всегда самое старое
            time: issue.created_on,
            author: author_str,
            text: issue.description
          }
        end

        # 2) Все предыдущие публичные комментарии (журналы)
        prev_journals = issue.journals.
          where("id < ?", journal.id).
          where(private_notes: false).
          where.not(notes: [nil, ""]).
          includes(:user).
          order(:id)

        prev_journals.each do |j|
          history_entries << {
            seq: j.id, # порядок журналов
            time: j.created_on,
            author: (j.user ? "#{j.user.name} <#{j.user.mail}>" : "unknown"),
            text: j.notes
          }
        end

        if history_entries.any?
          # НОВОЕ СВЕРХУ: сортируем по seq и переворачиваем
          sorted_entries = history_entries.sort_by { |e| e[:seq].to_i }.reverse

          quoted_history = sorted_entries.map do |e|
            ts = format_msk_time(e[:time])
            who = e[:author].to_s

            # Заголовок каждого блока
            block_header = []
            block_header << "От: #{who}" if who.present?
            block_header << "Отправлено: #{ts}" if ts.present?
            block_header << "Тема: #{issue.subject}" if issue.subject.present?

            # Цитирование текста
            quoted_text = e[:text].to_s.lines.map { |line| "> #{line}" }.join

            ([block_header.join("\n"), quoted_text].reject(&:blank?).join("\n"))
          end.join("\n\n-----\n\n")

          header_block = build_reply_header_block(
            issue,
            journal,
            recipient,
            (sender.present? && sender) || Setting.mail_from
          )

          if header_block.present?
            body = "#{body}\n\n#{header_block}\n\n----- История переписки -----\n#{quoted_history}"
          else
            body = "#{body}\n\n----- История переписки -----\n#{quoted_history}"
          end
        end
      end
      # ---- конец вставки ----

      # process reply-separator
      f = CustomField.find_by_name('helpdesk-reply-separator')
      reply_separator = issue.project.custom_value_for(f).try(:value)
      if !reply_separator.blank?
        body = reply_separator + "\n\n" + body
      end

      mail(
        :from     => sender.present? && sender || Setting.mail_from,
        :reply_to => sender.present? && sender || Setting.mail_from,
        :to       => recipient,
        :subject  => subject,
        :body     => body,
        :date     => Time.zone.now,
        :cc       => carbon_copy
      )
    else
      # fallback to a regular notifications email with redmine view
      @issue = issue
      @journal = journal
      @issue_url = url_for(:controller => 'issues', :action => 'show', :id => issue)

      mail(
        :from     => sender.present? && sender || Setting.mail_from,
        :reply_to => sender.present? && sender || Setting.mail_from,
        :to       => recipient,
        :subject  => subject,
        :date     => Time.zone.now,
        :template_path => 'mailer',
        :template_name => 'issue_edit',
        :cc            => carbon_copy
      )
    end

    # return mail object to deliver it
    mail
  end

  private

  # Appends a Redmine header field (name is prepended with 'X-Redmine-')
  def redmine_headers(h)
    h.each { |k, v| headers["X-Redmine-#{k}"] = v.to_s }
  end

  def self.token_for(object, rand = true)
    timestamp = object.send(object.respond_to?(:created_on) ? :created_on : :updated_on)
    hash = [
      "redmine",
      "#{object.class.name.demodulize.underscore}-#{object.id}",
      timestamp.strftime("%Y%m%d%H%M%S")
    ]
    hash << Redmine::Utils.random_hex(8) if rand
    host = Setting.mail_from.to_s.strip.gsub(%r{^.*@|>}, '')
    host = "#{::Socket.gethostname}.redmine" if host.empty?
    "#{hash.join('.')}@#{host}"
  end

  # Returns a Message-Id for the given object
  def self.message_id_for(object)
    token_for(object, true)
  end

  # Returns a uniq token for a given object referenced by all notifications
  # related to this object
  def self.references_for(object)
    token_for(object, false)
  end

  def message_id(object)
    @message_id_object = object
  end

  def references(object)
    @references_objects ||= []
    @references_objects << object
  end

  def helpdesk_ticket_for(issue)
    return nil unless issue.respond_to?(:helpdesk_ticket)
    issue.helpdesk_ticket
  rescue
    nil
  end

  def build_reply_header_block(issue, journal, recipient, sender_email)
    ticket = helpdesk_ticket_for(issue)

    # "От:" — стараемся показать клиента
    customer_email =
      (ticket && (ticket.respond_to?(:customer_email) ? ticket.customer_email : nil)).presence ||
      (ticket && (ticket.respond_to?(:email) ? ticket.email : nil)).presence ||
      recipient.to_s
    customer_email = extract_email(customer_email)

    ticket_name =
      (ticket && (ticket.respond_to?(:customer_name) ? ticket.customer_name : nil)).presence ||
      (ticket && (ticket.respond_to?(:name) ? ticket.name : nil)).presence

    # Приоритет: Redmine user по email, затем то, что пришло из helpdesk ticket
    customer_name = redmine_user_name_by_email(customer_email).presence || ticket_name

    from_str = if customer_name.present? && customer_email.present?
      "#{customer_name} <#{customer_email}>"
    else
      customer_email
    end

    # "Кому:" — адрес поддержки
    support_email =
      (ticket && (ticket.respond_to?(:support_email) ? ticket.support_email : nil)).presence ||
      sender_email.presence ||
      Setting.mail_from.to_s

    # "Отправлено:" — время сообщения, на которое отвечаем:
    sent_time = nil
    if journal.present?
      prev = issue.journals.
        where("id < ?", journal.id).
        where(private_notes: false).
        where.not(notes: [nil, ""]).
        order(:id).
        last
      sent_time = prev&.created_on
    end
    sent_time ||= issue.created_on

    subj = issue.subject.to_s
    sent_str = format_msk_time(sent_time)

    lines = []
    lines << "От: #{from_str}" if from_str.present?
    lines << "Отправлено: #{sent_str}" if sent_str.present?
    lines << "Кому: #{support_email}" if support_email.present?
    lines << "Тема: #{subj}" if subj.present?

    lines.join("\n")
  end

  def format_msk_time(t)
    return "" unless t
    msk = t.in_time_zone("Europe/Moscow")
    begin
      I18n.l(msk, format: :helpdesk_quote_header).to_s.strip
    rescue
      msk.strftime("%Y-%m-%d %H:%M:%S %Z")
    end
  end

  def redmine_user_name_by_email(email)
    e = extract_email(email).to_s.strip.downcase
    return nil if e.blank?

    if ::User.respond_to?(:find_by_mail)
      u = ::User.find_by_mail(e)
      return u.name if u
    end

    if defined?(::EmailAddress)
      ea = ::EmailAddress.includes(:user).where("LOWER(address) = ?", e).first
      return ea.user.name if ea&.user
    end

    nil
  rescue => ex
    Rails.logger.warn("HelpdeskMailer redmine_user_name_by_email failed: #{ex.class}: #{ex.message}")
    nil
  end

  def extract_email(value)
    v = value.to_s.strip
    return "" if v.empty?

    begin
      Mail::Address.new(v).address.to_s
    rescue
      v[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s
    end
  end
end
