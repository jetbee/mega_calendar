# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html
get '/calendar', :to => 'calendar#index'
get '/calendar/index', :to => 'calendar#index'
get '/calendar/get_events', :to => 'calendar#get_events'
get '/calendar/save_filters', :to => 'calendar#save_filters'
get '/calendar/get_saved_filters', :to => 'calendar#get_saved_filters'
get '/calendar/destroy_filter', :to => 'calendar#destroy_filter'
get '/calendar/change_holiday', :to => 'calendar#change_holiday'
get '/calendar/change_issue', :to => 'calendar#change_issue'
get '/calendar/export', :to => 'calendar#export'

# CalDAV routes
match '/caldav/:user_id/calendar/', :to => 'caldav#options', :via => :options
match '/caldav/:user_id/calendar/', :to => 'caldav#propfind', :via => :propfind
match '/caldav/:user_id/calendar/', :to => 'caldav#report', :via => :report
match '/caldav/:user_id/calendar/:event_id.ics', :to => 'caldav#get', :via => :get
match '/caldav/:user_id/calendar/:event_id.ics', :to => 'caldav#put', :via => :put
match '/caldav/:user_id/calendar/:event_id.ics', :to => 'caldav#delete', :via => :delete

get '/holidays/new', :to => 'holidays#new'
get '/holidays/create', :to => 'holidays#create'
get '/holidays/show', :to => 'holidays#show'
get '/holidays/edit', :to => 'holidays#edit'
get '/holidays/update', :to => 'holidays#update'
get '/holidays/destroy', :to => 'holidays#destroy'
get '/holidays', :to => 'holidays#index'
get '/holidays/index', :to => 'holidays#index'
