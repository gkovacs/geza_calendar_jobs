require! {
  getsecret
  moment
}

{cfy} = require 'cfy'

google = require 'googleapis'
calendar = google.calendar 'v3'

key = JSON.parse getsecret('google_service_account')

auth = new google.auth.JWT(
  key.client_email,
  null,
  key.private_key,
  ['https://www.googleapis.com/auth/calendar'],
  null
)

auth.projectId = key.project_id

calendarId = getsecret('available_meals_calendar_id')
primary_calendarId = getsecret('primary_calendar_id')

postpone_event = (evt, number, unit) ->
  new_start = moment(evt.start.dateTime).add(number, unit).format("YYYY-MM-DDTHH:mm:ssZ")
  new_end = moment(evt.end.dateTime).add(number, unit).format("YYYY-MM-DDTHH:mm:ssZ")
  evt.start.dateTime = new_start
  evt.end.dateTime = new_end

delete_passed_events = cfy ->*
  tokens = yield -> auth.authorize(it)
  #console.log tokens
  events = yield -> calendar.events.list {auth, calendarId}, {}, it
  event_list = events?0?items
  for evt in event_list
    if not evt?start? or not evt?end?
      continue
    start_time = moment(new Date(evt.start.dateTime))
    end_time = moment(new Date(evt.end.dateTime))
    if moment().add(1, 'hours') >= start_time
      # already passed
      eventId = evt.id
      if evt.recurrence and start_time.add(1, 'weeks') < end_time and evt.recurrence[0].indexOf('RRULE:FREQ=WEEKLY') != -1
        postpone_event evt, 1, 'weeks'
        yield -> calendar.events.patch {auth, calendarId, eventId, resource: evt}, it
      else
        yield -> calendar.events.delete {auth, calendarId, eventId}, it

replace_calendly_urls = cfy ->*
  timeMin = moment().format("YYYY-MM-DDTHH:mm:ssZ")
  events = yield -> calendar.events.list {auth, calendarId: primary_calendarId, timeMin}, {}, it
  event_list = events?0?items
  for evt in event_list
    eventId = evt.id
    if evt.description?
      if evt.description.indexOf('https://calendly.com/cancellations/') != -1 or evt.description.indexOf('https://calendly.com/reschedulings/') != -1
        ndesc = []
        for description_line in evt.description.split('\n')
          if description_line.indexOf('https://calendly.com/cancellations/') != -1 or description_line.indexOf('https://calendly.com/reschedulings/') != -1
            ndesc.push 'https://calendly.com/dashboard'
          else
            ndesc.push description_line
        evt.description = ndesc.join('\n')
        yield -> calendar.events.patch {auth, calendarId: primary_calendarId, eventId, resource: evt}, it

add_scheduling_links = cfy ->*
  events = yield -> calendar.events.list {auth, calendarId}, {}, it
  event_list = events?0?items
  for evt in event_list
    if not evt?start? or not evt?end?
      continue
    eventId = evt.id
    start_time = moment(new Date(evt.start.dateTime))
    end_time = moment(new Date(evt.end.dateTime))
    if evt.summary == 'available' or evt.summary == '[dinner] available' or evt.summary == '[lunch] available'
      meal_type = 'lunch'
      if start_time.hour() >= 15 # after 3pm
        meal_type = 'dinner'
      title_printable = "[#{meal_type}] available #{start_time.format('hh:mma')} - #{end_time.format('hh:mma')} book at https://gkovacs.com/meet"
      description_printable = '<a href="https://www.gkovacs.com/meet">https://www.gkovacs.com/meet</a>'
      evt.description = description_printable
      evt.summary = title_printable
      yield -> calendar.events.patch {auth, calendarId, eventId, resource: evt}, it

delete_passed_events()
replace_calendly_urls()
add_scheduling_links()