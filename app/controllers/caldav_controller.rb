class CaldavController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :check_if_login_required
  skip_before_action :require_login if defined?(require_login)
  skip_before_action :find_current_user if defined?(find_current_user)

  prepend_before_action :authenticate_user
  before_action :set_user
  before_action :check_plugin_right
  
  def authenticate_user
    authenticate_with_http_basic do |username, password|
      user = User.try_to_login(username, password)
      if user
        User.current = user
        Thread.current[:user] = user
        @current_user = User.current # ← ここで確実にセット
        Rails.logger.info "CalDAV login success: #{user.login}"
      else
        render plain: 'Access Denied', status: :unauthorized
      end
    end || render(plain: 'Authorization required', status: :unauthorized)
  end

  def set_user
    @current_user ||= User.current
  end

    def check_plugin_right
      Rails.logger.info "Check plugin right: User.current=#{User.current.inspect} / @current_user=#{@current_user.inspect}"
      right = (!Setting.plugin_mega_calendar['allowed_users'].blank? && 
               Setting.plugin_mega_calendar['allowed_users'].include?(@current_user.id.to_s))
      unless right
        render plain: 'Unauthorized', status: :unauthorized
      end
    end
  
    def calenar_propfind
      response.headers['DAV'] = '1, 2, 3, calendar-access'
      response.headers['Content-Type'] = 'application/xml; charset=utf-8'
    
      filters = UserFilter.where(user_id: params[:user_id])
      user = User.find(params[:user_id]) rescue nil
      username = user&.login || "user#{params[:user_id]}"
    
      builder = Nokogiri::XML::Builder.new do |xml|
        xml['d'].multistatus(
          'xmlns:d' => 'DAV:',
          'xmlns:cs' => 'http://calendarserver.org/ns/',
          'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav'
        ) do
    
          # トップコレクション (/caldav/:user_id/)
          xml['d'].response do
            xml['d'].href "/caldav/#{params[:user_id]}/"
            xml['d'].propstat do
              xml['d'].prop do
                xml['d'].resourcetype do
                  xml['d'].collection
                end
              end
              xml['d'].status 'HTTP/1.1 200 OK'
            end
    
            # Thunderbirdはこれがないとエラーを出すが、404でOK
            xml['d'].propstat do
              xml['d'].prop do
                xml['d'].displayname
                xml['cs'].getctag
                xml['cal'].supported_calendar_component_set
              end
              xml['d'].status 'HTTP/1.1 404 Not Found'
            end
          end
    
          # 各カレンダー (/caldav/:user_id/calendar/:filter_id/)
          filters.each do |filter|
            display_name = filter.filter_name.presence || "Filter #{filter.id}"
            href = "/caldav/#{params[:user_id]}/calendar/#{filter.id}/"
    
            xml['d'].response do
              xml['d'].href href
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].resourcetype do
                    xml['d'].collection
                    xml['cal'].calendar
                  end
                  xml['d'].displayname display_name
                  xml['cs'].getctag Time.now.to_i.to_s
                  xml['cal'].supported_calendar_component_set do
                    xml['cal'].comp name: 'VEVENT'
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
            end
          end
        end
      end
    
      render xml: builder.to_xml
    end
        
    def filter_propfind
        response.headers['DAV'] = '1, 2, 3, calendar-access, calendar-schedule'
        response.headers['Content-Type'] = 'application/xml; charset=utf-8'
      
        doc = Nokogiri::XML(request.body.read) rescue nil
        depth = request.headers['Depth'].to_s
      
        if doc&.at_xpath('//d:prop/d:resourcetype', 'd' => 'DAV:')
          if params[:filter_id].present?
            return render xml: build_resourcetype_response("/caldav/#{@user.id}/calendar/#{params[:filter_id]}/"), status: :multi_status
          else
            return render xml: build_resourcetype_response("/caldav/#{@user.id}/calendar/"), status: :multi_status
          end

        elsif doc&.at_xpath('//d:prop/d:supported-report-set', 'd' => 'DAV:')
            return render xml: build_supported_report_set_response, status: :multi_status
        
        elsif doc&.at_xpath('//d:prop/d:current-user-privilege-set', 'd' => 'DAV:')
            return render xml: build_current_user_privilege_set_response, status: :multi_status
        
        elsif doc&.at_xpath('//d:prop/d:owner', 'd' => 'DAV:')
            render xml: build_owner_and_organizer_response, status: :multi_status

        elsif doc&.at_xpath('//d:prop/d:current-user-principal', 'd' => 'DAV:')
            render xml: build_principal_response, status: :multi_status

        else
            # 他のPROPFIND処理
            render xml: build_propfind_response
        end
    end

    def principal_propfind
        response.headers['DAV'] = '1, 2, 3, calendar-access'
        response.headers['Content-Type'] = 'application/xml; charset=utf-8'
      
        render xml: build_calendar_user_address_set_response, status: :multi_status
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
  
        # ここで filter_id を取得
        filter_id = params[:filter_id].presence
  
        Rails.logger.info "=== Converted Dates ==="
        Rails.logger.info "start_date: #{start_date}"
        Rails.logger.info "end_date: #{end_date}"
        
        render xml: build_calendar_query_response(start_date, end_date, filter_id), status: :multi_status
      # calendar-multigetリクエストの場合
      elsif doc.at_xpath('//C:calendar-multiget', 'C' => 'urn:ietf:params:xml:ns:caldav')
        # イベントIDを取得
        hrefs = doc.xpath('//D:href', 'D' => 'DAV:').map { |href| href.text }
        event_ids = hrefs.map { |href| href.split('/').last.gsub('.ics', '') }
        
        render xml: build_calendar_multiget_response(event_ids), status: :multi_status
      else
        render plain: 'Not Implemented', status: :not_implemented
      end
    end

def normalize_line_endings(calendar_data)
  calendar_data.gsub!("\r\n", "\n")
  calendar_data
end

def correct_allday(calendar_data)
  # 改行コードを正規化
  calendar_data = normalize_line_endings(calendar_data)

  # TZIDを最初にパースする
  current_tzid = calendar_data.match(/^TZID:(.+)$/)[1].strip rescue 'UTC'
  
  # 終日イベントを日時イベントに変換
  calendar_data.gsub!(/^DTSTART;VALUE=DATE:(\d{8})$/) do
    "DTSTART;TZID=#{current_tzid}:#{$1}T000000"
  end
  
  calendar_data.gsub!(/^DTEND;VALUE=DATE:(\d{8})$/) do
    "DTEND;TZID=#{current_tzid}:#{$1}T000000"
  end

  calendar_data
end

def correct_timezone(calendar_data)
  calendar_data.gsub("TZID:Tokyo Standard Time", "TZID:Asia/Tokyo")
end
  
def put
  calendar_data = request.body.read
  Rails.logger.info "calendar_data: #{calendar_data}"

  # All Day の救済
  corrected_calendar_data = correct_allday(calendar_data)
  # タイムゾーンの修正
  corrected_calendar_data = correct_timezone(corrected_calendar_data)
  Rails.logger.info "corrected_calendar_data: #{corrected_calendar_data}"

  begin
    # iCalendarデータを解析
    cal = Icalendar::Calendar.parse(corrected_calendar_data).first
    ical_event = cal.events.first
    Rails.logger.info "ical_event: #{ical_event.inspect}"
    
    # イベントの識別子を抽出
    event_id = ical_event.uid.to_s.split('@').first
    
    # 開始時刻、終了時刻を取得
    event_start_time = ical_event.dtstart.to_time
    event_end_time = ical_event.dtend.to_time
    sent_tzid = ical_event.dtstart.ical_params['tzid']&.first || 'UTC'
    
    # 設定ファイルに基づいたタイムゾーン
    setting_timezone = Setting.plugin_mega_calendar['timezone']
    setting_tz = ActiveSupport::TimeZone[setting_timezone]
    
    # 時刻を設定されたタイムゾーンへ変換
    start_time_converted = event_start_time.in_time_zone(sent_tzid).in_time_zone(setting_tz)
    end_time_converted = event_end_time.in_time_zone(sent_tzid).in_time_zone(setting_tz)
    
    # データベースからイベント取得 & 更新
    if event_id.start_with?('issue_')
      issue_id = event_id.sub('issue_', '')
      issue = Issue.find(issue_id)
      
      if issue
        # 特定の時刻情報がない場合、つまり終日イベントの場合
        if start_time_converted.hour == 0 && start_time_converted.min == 0 && end_time_converted.hour == 0 && end_time_converted.min == 0
          Rails.logger.info "AllDay!: #{start_time_converted.inspect}/#{end_time_converted.inspect}"
          # end日付は1日前に。ただし、start より前にはしない
          if start_time_converted.to_date <  end_time_converted.to_date
            end_time_converted = end_time_converted - 1.day
          end
          # 日付更新
          issue.update(start_date: start_time_converted.to_date, due_date: end_time_converted.to_date)
          # 時刻情報がない場合、ticket_timeレコードを削除
          TicketTime.where(issue_id: issue_id).destroy_all
        else
          Rails.logger.info "Not AllDay!: #{start_time_converted.inspect}/#{end_time_converted.inspect}"
          # 日付更新
          issue.update(start_date: start_time_converted.to_date, due_date: end_time_converted.to_date)
          # 時刻情報がある場合、ticket_timeレコードを更新または作成
          ticket_time = TicketTime.find_or_initialize_by(issue_id: issue_id)
          ticket_time.update(
            time_begin: start_time_converted.strftime("%H:%M"),
            time_end: end_time_converted.strftime("%H:%M")
          )
        end

        render plain: 'OK', status: :ok
      else
        render plain: 'Not Found', status: :not_found
      end
    elsif event_id.start_with?('holiday_')
      holiday_id = event_id.sub('holiday_', '')
      holiday = Holiday.find(holiday_id)

      if holiday
        # 同様に処理
        holiday.update(start: start_time_converted.to_date, end: end_time_converted.to_date)
        
        if start_time_converted.hour == 0 && start_time_converted.min == 0 && end_time_converted.hour == 0 && end_time_converted.min == 0
          TicketTime.where(issue_id: holiday_id).destroy_all
        else
          ticket_time = TicketTime.find_or_initialize_by(issue_id: holiday_id)
          ticket_time.update(
            time_begin: start_time_converted.strftime("%H:%M"),
            time_end: end_time_converted.strftime("%H:%M")
          )
        end

        render plain: 'OK', status: :ok
      else
        render plain: 'Not Found', status: :not_found
      end
    else
      render plain: 'Invalid Event ID', status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "Error updating event: #{e.message}"
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
        response.headers['MS-Author-Via'] = 'DAV'
        response.headers['Accept-Ranges'] = 'bytes'
        response.headers['Content-Type'] = 'text/html; charset=UTF-8'
        head :ok
      end
      
    private
  
    def set_user
      @user = User.find(params[:user_id])
    end
  
    def build_propfind_response
        builder = Nokogiri::XML::Builder.new do |xml|
          xml.multistatus('xmlns:D' => 'DAV:', 'xmlns:C' => 'urn:ietf:params:xml:ns:caldav', 'xmlns:CS' => 'http://calendarserver.org/ns/') do
            xml.response do
              xml.href("/caldav/#{@user.id}/calendar/")
              
              # 200 OKのpropstat（存在するプロパティ）
              xml.propstat do
                xml.prop do
                  xml['D'].resourcetype do
                    xml['D'].collection
                    xml['C'].calendar
                  end
                  xml['D'].displayname @user.name
                  xml['D'].owner { xml['D'].href("/caldav/#{@user.id}/principals/") }
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
      
              # 404のpropstat（未対応プロパティ）
              xml.propstat do
                xml.prop do
                  xml['CS'].organizer
                end
                xml.status 'HTTP/1.1 404 Not Found'
              end
            end
          end
        end
        builder.to_xml
    end
        
    def build_calendar_query_response(start_date = nil, end_date = nil, filter_id = nil)
        events = get_events(start_date, end_date, filter_id)
      
        builder = Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus('xmlns:d' => 'DAV:', 'xmlns:c' => 'urn:ietf:params:xml:ns:caldav') do
            events.each do |event_data|
              xml['d'].response do
                xml['d'].href "/caldav/#{@user.id}/calendar/#{event_data[:id]}.ics"
                xml['d'].propstat do
                  xml['d'].prop do
                    xml['d'].getetag "\"#{event_data[:etag]}\""
                  end
                  xml['d'].status 'HTTP/1.1 200 OK'
                end
              end
            end
          end
        end
      
        builder.to_xml
    end

      
    def build_resourcetype_response(href)
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus('xmlns:d' => 'DAV:', 'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav') do
            xml['d'].response do
              xml['d'].href href
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].resourcetype do
                    xml['d'].collection
                    xml['cal'].calendar
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
            end
          end
        end.to_xml
    end

    def build_supported_report_set_response
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus(
            'xmlns:d' => 'DAV:',
            'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav',
            'xmlns:cs' => 'http://calendarserver.org/ns/'
          ) do
            xml['d'].response do
              xml['d'].href request.path
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].supported_report_set do
                    %w[
                      sync-collection
                      expand-property
                      principal-match
                      principal-property-search
                      principal-search-property-set
                    ].each do |report_name|
                      xml['d'].supported_report do
                        xml['d'].report { xml['d'].send(report_name.tr('-', '_')) }
                      end
                    end
      
                    %w[
                      calendar-multiget
                      calendar-query
                      free-busy-query
                    ].each do |cal_report|
                      xml['d'].supported_report do
                        xml['d'].report { xml['cal'].send(cal_report.tr('-', '_')) }
                      end
                    end
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
            end
          end
        end.to_xml
    end
      
    def build_current_user_privilege_set_response
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus(
            'xmlns:d' => 'DAV:',
            'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav'
          ) do
            xml['d'].response do
              # href: 権限情報の対象として "principals" URL を使用する
              xml['d'].href "/caldav/#{@user.id}/principals/"
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].current_user_privilege_set do
                    %w[
                      write
                      write-properties
                      write-content
                      unlock
                      bind
                      unbind
                      write-acl
                      read
                      read-acl
                      read-current-user-privilege-set
                    ].each do |priv|
                      xml['d'].privilege { xml['d'].send(priv.tr('-', '_')) }
                    end
                    xml['d'].privilege { xml['cal'].read_free_busy }
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
            end
          end
        end.to_xml
    end

    def build_owner_and_organizer_response
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus(
            'xmlns:d' => 'DAV:',
            'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav',
            'xmlns:cs' => 'http://calendarserver.org/ns/'
          ) do
            xml['d'].response do
              xml['d'].href request.path
      
              # owner (200 OK)
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].owner do
                    xml['d'].href "/caldav/#{@user.id}/principals/"
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
      
              # organizer (存在しない → 404)
              xml['d'].propstat do
                xml['d'].prop do
                  xml['cs'].organizer
                end
                xml['d'].status 'HTTP/1.1 404 Not Found'
              end
            end
          end
        end.to_xml
    end

    def build_principal_response
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus(
            'xmlns:d' => 'DAV:',
            'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav'
          ) do
            xml['d'].response do
              xml['d'].href request.path
      
              # 1. current-user-principal + resourcetype（200 OK）
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].current_user_principal do
                    xml['d'].href "/caldav/#{@user.id}/principals/"
                  end
                  xml['d'].resourcetype do
                    xml['d'].collection
                    xml['cal'].calendar
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
      
              # 2. principal-URL は未対応（404）
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].principal_URL
                end
                xml['d'].status 'HTTP/1.1 404 Not Found'
              end
            end
          end
        end.to_xml
    end

    def build_calendar_user_address_set_response
        user_href = "/caldav/#{@user.id}/principals/"
      
        Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus(
            'xmlns:d' => 'DAV:',
            'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav'
          ) do
            xml['d'].response do
              xml['d'].href user_href
              xml['d'].propstat do
                xml['d'].prop do
                  xml['cal'].calendar_user_address_set do
                    xml['d'].href "mailto:#{@user.mail}"
                    xml['d'].href user_href
                  end
                end
                xml['d'].status "HTTP/1.1 200 OK"
              end
            end
          end
        end.to_xml
    end
      
    def build_icalendar(event)
      Rails.logger.info "=== build_icalendar ==="
      Rails.logger.info "event: #{event.inspect}"
    
      return '' unless event.is_a?(Hash)
    
      calendar = Icalendar::Calendar.new
      
      # 設定されたタイムゾーンを取得
      timezone = Setting.plugin_mega_calendar['timezone']
      tz = ActiveSupport::TimeZone[timezone]
      
      # タイムゾーンの設定を追加
      calendar.timezone do |tz|
        tz.tzid = timezone
        
        # 標準時間の設定
        tz.standard do |s|
          s.tzoffsetfrom = tz.formatted_offset
          s.tzoffsetto   = tz.formatted_offset
          s.tzname       = tz.name
          s.dtstart      = '19700101T000000'
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
        # ローカルタイムゾーンの時間を解析
        start_time = Time.parse(event[:start])
        end_time =
          if event[:end].present?
            Time.parse(event[:end])
          else
            start_time + 1.day
          end
        
        # ローカルタイムゾーンの時間をUTCに変換
        start_time_utc = start_time.in_time_zone(timezone).utc
        end_time_utc = end_time.in_time_zone(timezone).utc
        
        # UTCでiCalendarイベントを作成
        ical_event.dtstart = Icalendar::Values::DateTime.new(start_time_utc, 'tzid' => 'UTC')
        ical_event.dtend   = Icalendar::Values::DateTime.new(end_time_utc, 'tzid' => 'UTC')
      end
    
      ical_event.summary = event[:title]
      ical_event.uid     = "#{event[:id]}@yourdomain.com"
      ical_event.dtstamp = Time.now.utc
      calendar.add_event(ical_event)
    
      calendar.to_ical
    end
        
    def get_events_by_ids(event_ids)
      events = []
    
      event_ids.each do |id|
        if id.start_with?('issue_')
          issue_id = id.sub('issue_', '')
          begin
            events << Issue.find(issue_id)
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn "Issue not found: #{issue_id}"
          end
        elsif id.start_with?('holiday_')
          holiday_id = id.sub('holiday_', '')
          begin
            events << Holiday.find(holiday_id)
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn "Holiday not found: #{holiday_id}"
          end
        end
      end
    
      events
    end

    def build_calendar_multiget_response(event_ids)
        events = get_events_by_ids(event_ids)
        # 設定ファイルからタイムゾーンを取得
        timezone = Setting.plugin_mega_calendar['timezone']
        tz = ActiveSupport::TimeZone[timezone]
    
        builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
            xml['d'].multistatus('xmlns:d' => 'DAV:', 'xmlns:c' => 'urn:ietf:params:xml:ns:caldav') do
                events.each do |event|
                    start_date = event.start_date || Date.today
                    end_date = event.due_date || start_date
    
                    ticket_time = TicketTime.find_by(issue_id: event.id)
                    time_format = '%Y%m%dT%H%M%SZ'
    
                    dtstart_line, dtend_line = if ticket_time&.time_begin && ticket_time&.time_end
                      # 設定されたタイムゾーンで構築
                      start_dt_local = Time.new(
                        start_date.year,
                        start_date.month,
                        start_date.day,
                        ticket_time.time_begin.hour,
                        ticket_time.time_begin.min,
                        0,
                        tz.formatted_offset
                      )
                    
                      end_dt_local = Time.new(
                        end_date.year,
                        end_date.month,
                        end_date.day,
                        ticket_time.time_end.hour,
                        ticket_time.time_end.min,
                        0,
                        tz.formatted_offset
                      )
                    
                      # ローカルタイム → UTC にしてiCalフォーマットに
                      [
                        "DTSTART:#{start_dt_local.utc.strftime(time_format)}",
                        "DTEND:#{end_dt_local.utc.strftime(time_format)}"
                      ]
                    else
                      [
                        "DTSTART;VALUE=DATE:#{start_date.strftime('%Y%m%d')}",
                        "DTEND;VALUE=DATE:#{(end_date + 1).strftime('%Y%m%d')}"
                      ]
                    end
                                              
                    calendar_data = <<~ICAL
                        BEGIN:VCALENDAR
                        PRODID:icalendar-ruby
                        CALSCALE:GREGORIAN
                        VERSION:2.0
                        BEGIN:VEVENT
                        CREATED:#{event.created_on.utc.strftime(time_format)}
                        DTSTAMP:#{event.updated_on.utc.strftime(time_format)}
                        LAST-MODIFIED:#{event.updated_on.utc.strftime(time_format)}
                        SEQUENCE:#{event.updated_on.to_i}
                        UID:issue_#{event.id}
                        #{dtstart_line}
                        #{dtend_line}
                        STATUS:CONFIRMED
                        SUMMARY:##{event.id} #{event.subject}#{event.estimated_hours ? " [#{event.estimated_hours}h]" : ""}
                        DESCRIPTION:#{Setting.protocol}://#{Setting.host_name}/issues/#{event.id}
                        ATTACH;VALUE=URI:#{Setting.protocol}://#{Setting.host_name}/issues/#{event.id}
                        END:VEVENT
                        END:VCALENDAR
                    ICAL
    
                    xml['d'].response do
                        xml['d'].href "/caldav/#{@user.id}/calendar/issue_#{event.id}.ics"
    
                        xml['d'].propstat do
                            xml['d'].prop do
                                xml['d'].getetag "\"#{event.updated_on.to_i}\""
                                xml['c'].send('calendar-data') do
                                    xml.cdata calendar_data.strip
                                end
                            end
                            xml['d'].status 'HTTP/1.1 200 OK'
                        end
    
                        xml['d'].propstat do
                            xml['d'].prop { xml['d'].displayname }
                            xml['d'].status 'HTTP/1.1 404 Not Found'
                        end
                    end
                end
            end
        end
    
        builder.to_xml
    end
              
    def query_filter(model, filters)
      condition = [""]
  
      condition[0] << "(" + (model == 'Holiday' ? 'holidays.user_id' : 'issues.assigned_to_id')+' IN (?) OR ' + (model == 'Holiday' ? 'holidays.user_id' : 'issues.assigned_to_id') + ' IN (SELECT user_id FROM groups_users WHERE group_id IN (?)) OR ' + (model == 'Holiday' ? 'holidays.user_id' : 'issues.assigned_to_id') + " IS NULL)"
      condition << Setting.plugin_mega_calendar['displayed_users']
      condition << Setting.plugin_mega_calendar['displayed_users']
        
      filters.keys.each do |x|
        filter_param = filters[x]
        filter = $mc_filters[x]
        if((filter_param[:enabled].to_s != 'true') || (filter_param['enabled'].to_s != 'true') || ((model == 'Holiday' && filter[:db_field_holiday].blank?) || (model == 'Issue' && filter[:db_field].blank?)))
          next
        end
        condition[0] << ' AND '
        if (filter[:condition].blank? && model == 'Issue') || (filter[:condition_holiday].blank? && model == 'Holiday')
          condition[0] << (model == 'Issue' ? filter[:db_field] : filter[:db_field_holiday]) + ' '
          if filter_param[:operator] == 'contains'
            condition[0] << 'IN '
          elsif filter_param[:operator] == 'not_contains'
            condition[0] << 'NOT IN '
          end
          condition[0] << '(?)'
          condition << filter_param[:value]
        else
          tmpcondition = (model == 'Issue' ? filter[:condition].gsub('##FIELD_ID##',filter[:db_field]) : filter[:condition_holiday].gsub('##FIELD_ID##',filter[:db_field_holiday])) + ' '
          count_values = tmpcondition.scan(/(?=\?)/).count
          if filter_param[:operator] == 'contains'
            tmpcondition = tmpcondition.gsub('##OPERATOR##','IN')
          elsif filter_param[:operator] == 'not_contains'
            tmpcondition = tmpcondition.gsub('##OPERATOR##','NOT IN')
          end
          condition[0] << tmpcondition
          count_values.times.each do
            condition << filter_param[:value]
          end
        end
      end
      sql = ActiveRecord::Base.send(:sanitize_sql_array, condition)
      Rails.logger.info "Final SQL condition: #{sql}"
      Rails.logger.info "Raw condition array: #{condition.inspect}"
      return condition
    end
  
    def get_events(start_date = nil, end_date = nil, filter_id = nil)
      Rails.logger.info "=== get_events ==="
      Rails.logger.info "start_date: #{start_date}"
      Rails.logger.info "end_date: #{end_date}"
      Rails.logger.info "filter_id: #{filter_id}"
    
      start_date ||= Date.today.to_s
      end_date ||= (Date.today + 1.year).to_s
      start_date = Date.parse(start_date)
      end_date = Date.parse(end_date)
    
      Rails.logger.info "Parsed dates - start_date: #{start_date}, end_date: #{end_date}"
    
      issues = []
    
      if filter_id.present?
        uf = UserFilter.where(id: filter_id, user_id: @user.id).first
        if uf.present?
          begin
            filter_code = JSON.parse(uf.filter_code).with_indifferent_access
            conditions = query_filter('Issue', filter_code)
            issues = Issue.where(conditions).where(
              '(start_date <= ? AND (due_date IS NULL OR due_date >= ?))', end_date, start_date
            )
          rescue => e
            Rails.logger.warn "Error processing filter: #{e.message}"
          end
        else
          Rails.logger.warn "UserFilter not found or not owned by user: #{filter_id}"
        end
      else
        issues += Issue.where([
          '((issues.start_date <= ? AND issues.due_date >= ?) OR (issues.start_date BETWEEN ? AND ?) OR (issues.due_date BETWEEN ? AND ?))',
          start_date, end_date, start_date, end_date, start_date, end_date
        ])
        issues += Issue.where([
          'issues.start_date >= ? AND issues.start_date <= ? AND issues.due_date IS NULL',
          start_date, end_date
        ])
        issues += Issue.where([
          'issues.start_date IS NULL AND issues.due_date <= ? AND issues.due_date >= ?',
          end_date, start_date
        ])
        if Setting.plugin_mega_calendar['display_empty_dates'].to_i == 1
          issues += Issue.where([
            'issues.start_date IS NULL AND issues.due_date IS NULL AND (issues.created_on BETWEEN ? AND ?)',
            start_date, end_date
          ])
        end
        issues = issues.compact.uniq
      end
    
      holidays = Holiday.where([
        '((holidays.start <= ? AND holidays.end >= ?) OR (holidays.start BETWEEN ? AND ?) OR (holidays.end BETWEEN ? AND ?))',
        start_date, end_date, start_date, end_date, start_date, end_date
      ])
    
      Rails.logger.info "Found holidays: #{holidays.size}"
    
      events = []
    
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
    
      issues.each do |i|
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
          title: "##{i.id} #{i.subject}",
          start: issue_start_date.to_date.to_s + tbegin,
          end: issue_end_date.to_date.to_s + tend,
          etag: i.updated_on.to_i.to_s
        }
    
        if tbegin.blank? || tend.blank?
          event[:allDay] = true
          event[:end] = (issue_end_date + 1.day).to_date.to_s if !issue_end_date.blank? && tend.blank?
        end
    
        events << event
      end
      events
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

    def build_supported_report_set_response
        builder = Nokogiri::XML::Builder.new do |xml|
          xml['d'].multistatus('xmlns:d' => 'DAV:', 'xmlns:cal' => 'urn:ietf:params:xml:ns:caldav', 'xmlns:oc' => 'http://owncloud.org/ns') do
            xml['d'].response do
              xml['d'].href request.path
              xml['d'].propstat do
                xml['d'].prop do
                  xml['d'].supported_report_set do
                    %w[
                      sync-collection
                      expand-property
                      principal-match
                      principal-property-search
                      principal-search-property-set
                    ].each do |report_name|
                      xml['d'].supported_report do
                        xml['d'].report { xml['d'].send(report_name.gsub('-', '_')) }
                      end
                    end
                    %w[
                      calendar-multiget
                      calendar-query
                      free-busy-query
                    ].each do |cal_report|
                      xml['d'].supported_report do
                        xml['d'].report { xml['cal'].send(cal_report.gsub('-', '_')) }
                      end
                    end
                    %w[
                      filter-comments
                      filter-files
                    ].each do |oc_report|
                      xml['d'].supported_report do
                        xml['d'].report { xml['oc'].send(oc_report.gsub('-', '_')) }
                      end
                    end
                  end
                end
                xml['d'].status 'HTTP/1.1 200 OK'
              end
            end
          end
        end
        builder.to_xml
    end
    
end 
