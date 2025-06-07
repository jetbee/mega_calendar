class CaldavController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_user
  before_action :check_plugin_right
  before_action :set_user

  def authenticate_user
    authenticate_or_request_with_http_basic do |username, password|
      @current_user = User.try_to_login(username, password)
      @current_user.present?
    end
  end

  def check_plugin_right
    right = (!Setting.plugin_mega_calendar['allowed_users'].blank? && 
             Setting.plugin_mega_calendar['allowed_users'].include?(@current_user.id.to_s))
    unless right
      render plain: 'Unauthorized', status: :unauthorized
    end
  end

  def propfind
    response.headers['DAV'] = '1, 2, 3, calendar-access, calendar-schedule'
    response.headers['Allow'] = 'OPTIONS, PROPFIND, GET, HEAD, REPORT, PROPPATCH, PUT, DELETE, POST, COPY, MOVE'
    response.headers['Content-Type'] = 'application/xml; charset=utf-8'
    
    render xml: build_propfind_response
  end

  def report
    response.headers['Content-Type'] = 'application/xml; charset=utf-8'
    
    # REPORTリクエストのボディを解析
    body = request.body.read
    Rails.logger.info "=== REPORT Request Body ==="
    Rails.logger.info body
    
    doc = Nokogiri::XML(body)
    
    # calendar-queryリクエストの場合
    if doc.at_xpath('//C:calendar-query', 'C' => 'urn:ietf:params:xml:ns:caldav')
      # 時間範囲を取得
      time_range = doc.at_xpath('//C:time-range', 'C' => 'urn:ietf:params:xml:ns:caldav')
      start_date = time_range['start'] if time_range
      end_date = time_range['end'] if time_range
      
      Rails.logger.info "=== Calendar Query ==="
      Rails.logger.info "start_date: #{start_date}"
      Rails.logger.info "end_date: #{end_date}"
      
      # CalDAVの日付フォーマットを変換
      if start_date
        start_date = Time.strptime(start_date, '%Y%m%dT%H%M%SZ').strftime('%Y-%m-%d')
      end
      if end_date
        end_date = Time.strptime(end_date, '%Y%m%dT%H%M%SZ').strftime('%Y-%m-%d')
      end
      
      Rails.logger.info "=== Converted Dates ==="
      Rails.logger.info "start_date: #{start_date}"
      Rails.logger.info "end_date: #{end_date}"
      
      render xml: build_calendar_query_response(start_date, end_date)
    # calendar-multigetリクエストの場合
    elsif doc.at_xpath('//C:calendar-multiget', 'C' => 'urn:ietf:params:xml:ns:caldav')
      # イベントIDを取得
      hrefs = doc.xpath('//D:href', 'D' => 'DAV:').map { |href| href.text }
      event_ids = hrefs.map { |href| href.split('/').last.gsub('.ics', '') }
      
      render xml: build_calendar_multiget_response(event_ids)
    else
      render plain: 'Not Implemented', status: :not_implemented
    end
  end

  def put
    calendar_data = request.body.read
    if save_calendar_event(calendar_data)
      render plain: 'OK', status: :created
    else
      render plain: 'Error', status: :internal_server_error
    end
  end

  def get
    event_id = params[:event_id]
    event = get_event_by_id(event_id)
    
    if event
      response.headers['Content-Type'] = 'text/calendar; charset=utf-8'
      render text: build_icalendar({
        id: event.id,
        title: event.is_a?(Issue) ? "#{event.id} - #{event.subject}" : "休暇",
        start: event.is_a?(Issue) ? event.start_date.to_s : event.start.to_s,
        end: event.is_a?(Issue) ? event.due_date.to_s : (event.end + 1.day).to_s,
        etag: event.updated_on.to_i.to_s,
        allDay: true
      })
    else
      render plain: 'Not Found', status: :not_found
    end
  end

  def delete
    event_id = params[:event_id]
    if delete_event(event_id)
      render plain: 'OK', status: :no_content
    else
      render plain: 'Not Found', status: :not_found
    end
  end

  def options
    response.headers['DAV'] = '1, 2, 3, calendar-access, calendar-schedule'
    response.headers['Allow'] = 'OPTIONS, PROPFIND, GET, HEAD, REPORT, PROPPATCH, PUT, DELETE, POST, COPY, MOVE'
    render plain: '', status: :ok
  end

  private

  def set_user
    @user = User.find(params[:user_id])
  end

  def build_propfind_response
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav') do
        xml.response do
          xml.href("/caldav/#{@user.id}/calendar/")
          xml.propstat do
            xml.prop do
              xml['D'].resourcetype do
                xml['D'].collection
                xml['C'].calendar
              end
              xml['D'].displayname @user.name
              xml['C'].calendar_description 'Mega Calendar'
              xml['C'].supported_calendar_component_set do
                xml['C'].comp name: 'VEVENT'
                xml['C'].comp name: 'VTODO'
              end
              xml['D'].getetag '"' + Time.now.to_i.to_s + '"'
              xml['C'].calendar_timezone 'UTC'
            end
            xml.status 'HTTP/1.1 200 OK'
          end
        end
      end
    end
    builder.to_xml
  end

  def build_calendar_query_response(start_date = nil, end_date = nil)
    events = get_events(start_date, end_date)
  
    builder = Nokogiri::XML::Builder.new do |xml|
      xml['d'].multistatus('xmlns:d' => 'DAV:', 'xmlns:c' => 'urn:ietf:params:xml:ns:caldav') do
        events.each do |event_data|
          calendar_data = build_icalendar(event_data)
          xml['d'].response do
            xml['d'].href "/caldav/#{@user.id}/calendar/#{event_data[:id]}.ics"
            xml['d'].propstat do
              xml['d'].prop do
                xml['d'].getetag "\"#{event_data[:etag]}\""
                xml['d'].displayname event_data[:title]
                xml['c'].calendar_data do
                  xml << "<![CDATA[#{calendar_data}]]>"
                end
              end
              xml['d'].status 'HTTP/1.1 200 OK'
            end
          end
        end
      end
    end
  
    builder.to_xml
  end
    
  def build_icalendar(event)
    Rails.logger.info "=== build_icalendar ==="
    Rails.logger.info "event: #{event.inspect}"
  
    return '' unless event.is_a?(Hash)
  
    calendar = Icalendar::Calendar.new
    
    # タイムゾーンの設定を追加
    calendar.timezone do |tz|
      tz.tzid = 'Asia/Tokyo'
      
      # 標準時間の設定
      tz.standard do |s|
        s.tzoffsetfrom = '+0900'
        s.tzoffsetto   = '+0900'
        s.tzname       = 'JST'
        s.dtstart      = '19700101T090000'  # 明示的に09:00を指定
      end
    end
    
    ical_event = Icalendar::Event.new
  
    # 判定：時間が含まれるかで日付型を変える
    is_all_day = event[:allDay] || (!event[:start].include?(' ') && !event[:end].to_s.include?(' '))
  
    if is_all_day
      start_date = Date.parse(event[:start])
      end_date =
        if event[:end].present?
          Date.parse(event[:end])
        else
          start_date + 1
        end
      ical_event.dtstart = Icalendar::Values::Date.new(start_date)
      ical_event.dtend   = Icalendar::Values::Date.new(end_date)
    else
      start_time = Time.parse(event[:start])
      end_time =
        if event[:end].present?
          Time.parse(event[:end])
        else
          start_time + 1.day
        end
      # タイムゾーンIDを明示的に指定
      ical_event.dtstart = Icalendar::Values::DateTime.new(start_time, 'tzid' => 'Asia/Tokyo')
      ical_event.dtend   = Icalendar::Values::DateTime.new(end_time, 'tzid' => 'Asia/Tokyo')
    end
  
    ical_event.summary = event[:title]
    ical_event.uid     = "#{event[:id]}@yourdomain.com"
    ical_event.dtstamp = Time.now.utc
    calendar.add_event(ical_event)
  
    calendar.to_ical
  end
      
  def build_calendar_multiget_response(event_ids)
    events = get_events_by_ids(event_ids)
    
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav') do
        events.each do |event|
          xml.response do
            xml.href("/caldav/#{@user.id}/calendar/#{event.id}.ics")
            xml.propstat do
              xml.prop do
                xml['D'].getetag "\"#{event.updated_on.to_i}\""
                xml['C'].calendar_data do
                  xml.cdata build_icalendar({
                    id: event.id,
                    title: event.is_a?(Issue) ? "#{event.id} - #{event.subject}" : "休暇",
                    start: event.is_a?(Issue) ? event.start_date.to_s : event.start.to_s,
                    end: event.is_a?(Issue) ? event.due_date.to_s : (event.end + 1.day).to_s,
                    etag: event.updated_on.to_i.to_s
                  })
                end
              end
              xml.status 'HTTP/1.1 200 OK'
            end
          end
        end
      end
    end
    builder.to_xml
  end

  def get_events(start_date = nil, end_date = nil)
    Rails.logger.info "=== get_events ==="
    Rails.logger.info "start_date: #{start_date}"
    Rails.logger.info "end_date: #{end_date}"
    
    # デフォルトの日付範囲を設定
    start_date ||= Date.today.to_s
    end_date ||= (Date.today + 1.year).to_s

    # 日付をDateオブジェクトに変換
    start_date = Date.parse(start_date)
    end_date = Date.parse(end_date)

    Rails.logger.info "Parsed dates - start_date: #{start_date}, end_date: #{end_date}"

    # イベントを取得
    issues_condition = "1=1"  # デフォルトの条件
    holidays_condition = "1=1"  # デフォルトの条件

    # 休暇を取得
    holidays = Holiday.where([
      '((holidays.start <= ? AND holidays.end >= ?) OR (holidays.start BETWEEN ? AND ?) OR (holidays.end BETWEEN ? AND ?))',
      start_date, end_date, start_date, end_date, start_date, end_date
    ]).where(holidays_condition)

    Rails.logger.info "Found holidays: #{holidays.size}"

    # 課題を取得
    issues = Issue.where([
      '((issues.start_date <= ? AND issues.due_date >= ?) OR (issues.start_date BETWEEN ? AND ?) OR (issues.due_date BETWEEN ? AND ?))',
      start_date, end_date, start_date, end_date, start_date, end_date
    ]).where(issues_condition)

    Rails.logger.info "Found issues: #{issues.size}"

    # 開始日のみの課題
    issues2 = Issue.where([
      'issues.start_date >= ? AND issues.start_date <= ? AND issues.due_date IS NULL',
      start_date, end_date
    ]).where(issues_condition)

    # 終了日のみの課題
    issues3 = Issue.where([
      'issues.start_date IS NULL AND issues.due_date <= ? AND issues.due_date >= ?',
      end_date, start_date
    ]).where(issues_condition)

    # 日付なしの課題
    issues4 = []
    if Setting.plugin_mega_calendar['display_empty_dates'].to_i == 1
      issues4 = Issue.where([
        'issues.start_date IS NULL AND issues.due_date IS NULL AND (issues.created_on BETWEEN ? AND ?)',
        start_date, end_date
      ]).where(issues_condition)
    end

    # イベントを結合
    all_issues = (issues + issues2 + issues3 + issues4).compact.uniq

    # イベントを整形
    events = []
    
    # 休暇を追加
    holidays.each do |h|
      events << {
        id: "holiday_#{h.id}",
        title: (h.user.blank? ? '' : h.user.name + ' - ') + '休暇',
        start: h.start.to_date.to_s,
        end: (h.end + 1.day).to_date.to_s,
        allDay: true,
        etag: h.updated_on.to_i.to_s
      }
    end

    # 課題を追加
    all_issues.each do |i|
      ticket_time = TicketTime.where(issue_id: i.id).first rescue nil
      tbegin = ticket_time&.time_begin&.strftime(" %H:%M") || ''
      tend = ticket_time&.time_end&.strftime(" %H:%M") || ''

      issue_start_date = i.start_date || i.due_date
      issue_end_date = i.due_date || i.start_date

      if issue_start_date.blank? && issue_end_date.blank? && Setting.plugin_mega_calendar['display_empty_dates'].to_i == 1
        issue_start_date = i.created_on
        issue_end_date = i.created_on
      end

      event = {
        id: "issue_#{i.id}",
        title: "#{i.id} - #{i.subject}",
        start: issue_start_date.to_date.to_s + tbegin,
        end: issue_end_date.to_date.to_s + tend,
        etag: i.updated_on.to_i.to_s
      }

      if tbegin.blank? || tend.blank?
        event[:allDay] = true
        if !issue_end_date.blank? && tend.blank?
          event[:end] = (issue_end_date + 1.day).to_date.to_s
        end
      end

      events << event
    end

    events
  end

  def get_event_by_id(event_id)
    if event_id.start_with?('issue_')
      issue_id = event_id.sub('issue_', '')
      Issue.find(issue_id)
    elsif event_id.start_with?('holiday_')
      holiday_id = event_id.sub('holiday_', '')
      Holiday.find(holiday_id)
    end
  end

  def get_events_by_ids(event_ids)
    # 指定されたIDのイベントを取得
    events = []
    event_ids.each do |id|
      if id.start_with?('issue_')
        issue_id = id.sub('issue_', '')
        events << Issue.find(issue_id)
      elsif id.start_with?('holiday_')
        holiday_id = id.sub('holiday_', '')
        events << Holiday.find(holiday_id)
      end
    end
    events
  end

  def save_calendar_event(calendar_data)
    # iCalendarデータをパースして保存
    calendar = Icalendar::Calendar.parse(calendar_data).first
    event = calendar.events.first
    
    if event
      if event.uid.start_with?('issue_')
        issue_id = event.uid.sub('issue_', '')
        issue = Issue.find(issue_id)
        issue.update(
          start_date: event.dtstart.to_date,
          due_date: event.dtend.to_date
        )
      elsif event.uid.start_with?('holiday_')
        holiday_id = event.uid.sub('holiday_', '')
        holiday = Holiday.find(holiday_id)
        holiday.update(
          start: event.dtstart.to_date,
          end: event.dtend.to_date
        )
      end
      true
    else
      false
    end
  end

  def delete_event(event_id)
    if event_id.start_with?('issue_')
      issue_id = event_id.sub('issue_', '')
      issue = Issue.find(issue_id)
      issue.destroy
    elsif event_id.start_with?('holiday_')
      holiday_id = event_id.sub('holiday_', '')
      holiday = Holiday.find(holiday_id)
      holiday.destroy
    end
    true
  rescue ActiveRecord::RecordNotFound
    false
  end
end 