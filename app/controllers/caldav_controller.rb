class CalDAVController < ApplicationController
  before_action :check_plugin_right
  before_action :set_calendar

  def check_plugin_right
    user_id_of_api_key = '-1'
    unless params[:key].blank?
      user_id_of_api_key = User.find_by_api_key(params[:key]).id rescue '-1'
    end
    right = (!Setting.plugin_mega_calendar['allowed_users'].blank? && (Setting.plugin_mega_calendar['allowed_users'].include?(User.current.id.to_s) || Setting.plugin_mega_calendar['allowed_users'].include?(user_id_of_api_key.to_s)) ? true : false)
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
    
    case params[:report_type]
    when 'calendar-query'
      render xml: build_calendar_query_response
    when 'calendar-multiget'
      render xml: build_calendar_multiget_response
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

  private

  def set_calendar
    @calendar = Calendar.find_by(user_id: User.current.id)
  end

  def build_propfind_response
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav') do
        xml.response do
          xml.href("/caldav/#{User.current.id}/calendar")
          xml.propstat do
            xml.prop do
              xml['D'].resourcetype do
                xml['D'].collection
                xml['C'].calendar
              end
              xml['D'].displayname User.current.name
              xml['C'].calendar_description 'Mega Calendar'
              xml['C'].supported_calendar_component_set do
                xml['C'].comp name: 'VEVENT'
                xml['C'].comp name: 'VTODO'
              end
            end
            xml.status 'HTTP/1.1 200 OK'
          end
        end
      end
    end
    builder.to_xml
  end

  def build_calendar_query_response
    start_date = params[:start_date]
    end_date = params[:end_date]
    
    events = get_events(start_date, end_date)
    
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav') do
        events.each do |event|
          xml.response do
            xml.href("/caldav/#{User.current.id}/calendar/#{event.id}.ics")
            xml.propstat do
              xml.prop do
                xml['D'].getetag "\"#{event.etag}\""
                xml['C'].calendar_data event.to_ical
              end
              xml.status 'HTTP/1.1 200 OK'
            end
          end
        end
      end
    end
    builder.to_xml
  end

  def build_calendar_multiget_response
    event_ids = params[:event_ids]
    events = get_events_by_ids(event_ids)
    
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav') do
        events.each do |event|
          xml.response do
            xml.href("/caldav/#{User.current.id}/calendar/#{event.id}.ics")
            xml.propstat do
              xml.prop do
                xml['D'].getetag "\"#{event.etag}\""
                xml['C'].calendar_data event.to_ical
              end
              xml.status 'HTTP/1.1 200 OK'
            end
          end
        end
      end
    end
    builder.to_xml
  end

  def get_events(start_date, end_date)
    # 既存のget_eventsメソッドを利用
    CalendarController.new.get_events(start_date, end_date)
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
end 