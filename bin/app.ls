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
#meals_calendarId = getsecret('meals_calendar_id')
primary_calendarId = getsecret('primary_calendar_id')
#secondary_calendarId = getsecret('secondary_calendar_id')

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
      if evt.recurrence and start_time.add(1, 'weeks') < end_time and evt.recurrence.filter(it -> it.includes('RRULE:FREQ=WEEKLY')).length > 0
        # TODO: does not handle recurrence.EXDATE
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

/*
is_between_time = (evt, start, end) ->
  evt_start = moment(new Date(evt.start.dateTime))
  evt_end = moment(new Date(evt.end.dateTime))
  return (evt_start < end and evt_end >= start) or (evt_start <= end and evt_end > start)

to_timestamp_minutes = (moment_obj) ->
  Math.round(moment(moment_obj).seconds(0).milliseconds(0).unix() / 60)

get_nonconflicting_spans_all = (conflicting_events, start, end) ->
  start_timestamp_minutes = to_timestamp_minutes start
  end_timestamp_minutes = to_timestamp_minutes end
  length_minutes = end_timestamp_minutes - start_timestamp_minutes
  conflicts = [false]*length_minutes
  for evt in conflicting_events
    evt_start_minutes = to_timestamp_minutes(new Date(evt.start.dateTime))
    evt_end_minutes = to_timestamp_minutes(new Date(evt.end.dateTime))
    for offset from Math.max(0, evt_start_minutes - start_timestamp_minutes) til Math.min(length_minutes, evt_end_minutes - start_timestamp_minutes)
      conflicts[offset] = true
  #console.log conflicts
  start_time_to_lengths = [0]*length_minutes
  streak_start_idx = 0
  for val,idx in conflicts
    if val
      streak_start_idx = idx + 1
    else
      start_time_to_lengths[streak_start_idx] += 1
  #console.log start_time_to_lengths
  output = []
  for val,idx in start_time_to_lengths
    if val > 0
      span_start = moment(start).add(idx, 'minutes')
      span_end = moment(start).add(val, 'minutes')
      output.push {start: span_start, end: span_end, minutes: val}
  return output

get_nonconflicting_spans = (conflicting_events, start, end) ->
  output = get_nonconflicting_spans_all conflicting_events, start, end
  return output.filter(-> it.minutes >= 60)

nonditchable_and_nontentative = (evt) ->
  if not evt?
    return false
  summary = evt.summary
  if not summary?
    return false
  return not (summary.includes('[ditchable]') or summary.includes('[tentative]'))

create_available_meals = cfy ->*
  timeMin = moment().format("YYYY-MM-DDTHH:mm:ssZ")
  events_available_meals = (yield -> calendar.events.list {auth, calendarId, timeMin}, {}, it)?0?items
  events_meals = (yield -> calendar.events.list {auth, calendarId: meals_calendarId, timeMin}, {}, it)?0?items
  events_primary = (yield -> calendar.events.list {auth, calendarId: primary_calendarId, timeMin}, {}, it)?0?items
  events_secondary = (yield -> calendar.events.list {auth, calendarId: secondary_calendarId, timeMin}, {}, it)?0?items
  current_time = moment()
  today_start = moment(current_time).hours(0).minutes(0).seconds(0).milliseconds(0)
  events_meals_actual = events_meals.filter(nonditchable_and_nontentative)
  events_all_actual = events_primary.concat(events_secondary).concat(events_meals).filter(nonditchable_and_nontentative)
  console.log events_primary.filter(-> it.recurrence?)
  # TODO need to check overlap with recurring events as well
  for days_into_future from 0 til 1
    day = moment(today_start).add(days_into_future, 'days')
    next_day = moment(day).add(1, 'days')
    lunchtime_start = moment(day).hours(11).minutes(50)
    lunchtime_end = moment(day).hours(14)
    events_all_lunchtime = events_all_actual.filter(-> is_between_time(it, lunchtime_start, lunchtime_end))
    #console.log events_all_lunchtime
    #console.log get_nonconflicting_spans_all(events_all_lunchtime, lunchtime_start, lunchtime_end)
    available_meals_to_output = []
*/

delete_passed_events()
replace_calendly_urls()
add_scheduling_links()
#create_available_meals()
