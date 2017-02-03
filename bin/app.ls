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
meals_calendarId = getsecret('meals_calendar_id')
primary_calendarId = getsecret('primary_calendar_id')
secondary_calendarId = getsecret('secondary_calendar_id')

postpone_event = (evt, number, unit) ->
  new_start = moment(evt.start.dateTime).add(number, unit).format("YYYY-MM-DDTHH:mm:ssZ")
  new_end = moment(evt.end.dateTime).add(number, unit).format("YYYY-MM-DDTHH:mm:ssZ")
  evt.start.dateTime = new_start
  evt.end.dateTime = new_end

postpone_event_to_day = (evt, day) ->
  orig_start = moment(evt.start.dateTime)
  orig_end = moment(evt.end.dateTime)
  new_start = moment(day).hours(orig_start.hours()).minutes(orig_start.minutes()).format("YYYY-MM-DDTHH:mm:ssZ")
  new_end = moment(day).hours(orig_end.hours()).minutes(orig_start.minutes()).format("YYYY-MM-DDTHH:mm:ssZ")
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
      if is_weekly_recurring(evt) and start_time.add(1, 'weeks') < end_time
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
      span_end = moment(start).add(idx+val, 'minutes')
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

is_weekly_recurring = (evt) ->
  return evt.recurrence? and evt.recurrence.filter(-> it.includes('RRULE:FREQ=WEEKLY')).length > 0

get_recrule_day_of_week_indexes = (recrule_list) ->
  output = []
  output_set = {}
  days = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA']
  days_to_idx = {}
  for day,idx in days
    days_to_idx[day] = idx
  for recrule in recrule_list # [ 'RRULE:FREQ=WEEKLY;BYDAY=TU,TH' ]
    for recrule_part in recrule.split(';') # RRULE:FREQ=WEEKLY;BYDAY=TU,TH
      if not recrule_part.startsWith('BYDAY=')
        continue
      remainder = recrule_part.substr('BYDAY='.length) # BYDAY=TU,TH
      for day in remainder.split(',') # TU
        day_idx = days_to_idx[day]
        if not output_set[day_idx]?
          output.push day_idx
          output_set[day_idx] = true
  return output

get_next_time_given_day_of_week_indexes = (start, day_of_week_indexes) ->
  if day_of_week_indexes.length == 0
    return moment(start).add(1, 'weeks')
  start_day_of_week = start.weekday()
  greater_day_of_week_indexes = day_of_week_indexes.filter(-> it > start_day_of_week)
  if greater_day_of_week_indexes.length > 0
    # later in this week
    next_day_of_week_idx = greater_day_of_week_indexes[0]
    return moment(start).weekday(next_day_of_week_idx)
  next_day_of_week_idx = day_of_week_indexes[0]
  return moment(start).weekday(next_day_of_week_idx).add(1, 'weeks')

expand_recurring_events = (evt_list, start, end) ->
  output = []
  for evt in evt_list
    if is_weekly_recurring(evt)
      day_of_week_indexes = get_recrule_day_of_week_indexes evt.recurrence
      new_start_time = moment(new Date(evt.start.dateTime))
      while true
        if new_start_time >= end
          break
        if new_start_time > start
          new_evt = JSON.parse JSON.stringify evt
          delete new_evt.recurrence
          postpone_event_to_day new_evt, new_start_time
          output.push new_evt
        new_start_time = get_next_time_given_day_of_week_indexes(new_start_time, day_of_week_indexes)
    else
      output.push evt
  return output

create_available_meals = cfy ->*
  timeMin = moment().format("YYYY-MM-DDTHH:mm:ssZ")
  timeMax = moment().add(31, 'days').format("YYYY-MM-DDTHH:mm:ssZ")
  events_available_meals = (yield -> calendar.events.list {auth, calendarId, timeMin, timeMax}, {}, it)?0?items
  events_meals = (yield -> calendar.events.list {auth, calendarId: meals_calendarId, timeMin, timeMax}, {}, it)?0?items
  events_primary = (yield -> calendar.events.list {auth, calendarId: primary_calendarId, timeMin, timeMax}, {}, it)?0?items
  events_secondary = (yield -> calendar.events.list {auth, calendarId: secondary_calendarId, timeMin, timeMax}, {}, it)?0?items
  events_meals_actual = events_meals.filter(nonditchable_and_nontentative)
  events_all_actual = events_primary.concat(events_secondary).concat(events_meals).filter(nonditchable_and_nontentative)
  current_time = moment()
  today_start = moment(current_time).hours(0).minutes(0).seconds(0).milliseconds(0)
  end_time_recurrence_expansion = moment(today_start).add(31, 'days')
  events_meals_actual = expand_recurring_events events_meals_actual, today_start, end_time_recurrence_expansion
  events_all_actual = expand_recurring_events events_all_actual, today_start, end_time_recurrence_expansion
  all_available_meal_times = []
  for days_into_future from 0 til 7
    day = moment(today_start).add(days_into_future, 'days')
    day_weekday_num = day.weekday()
    if day_weekday_num == 6 or day_weekday_num == 0 # saturday or sunday
      continue
    next_day = moment(day).add(1, 'days')
    # lunch
    mealtime_start = moment(day).hours(11) # 11am
    mealtime_end = moment(day).hours(14) # 2pm
    events_mealtime_today = events_meals_actual.filter(-> is_between_time(it, mealtime_start, mealtime_end))
    if events_mealtime_today.length == 0
      events_all_mealtime_today = events_all_actual.filter(-> is_between_time(it, mealtime_start, mealtime_end))
      available_times = get_nonconflicting_spans(events_all_mealtime_today, mealtime_start, mealtime_end)
      for available_time in available_times
        all_available_meal_times.push available_time
    # dinner
    mealtime_start = moment(day).hours(17).minutes(0) # 5pm
    mealtime_end = moment(day).hours(20).minutes(30) # 8:30pm
    events_mealtime_today = events_meals_actual.filter(-> is_between_time(it, mealtime_start, mealtime_end))
    if events_mealtime_today.length == 0
      events_all_mealtime_today = events_all_actual.filter(-> is_between_time(it, mealtime_start, mealtime_end))
      available_times = get_nonconflicting_spans(events_all_mealtime_today, mealtime_start, mealtime_end)
      for available_time in available_times
        all_available_meal_times.push available_time
    #console.log events_all_lunchtime
    #console.log get_nonconflicting_spans_all(events_all_lunchtime, lunchtime_start, lunchtime_end)
  console.log all_available_meal_times
  # TODO compare against existing available events and delete the ones that should not exist, and create the ones that should exist

delete_passed_events()
replace_calendly_urls()
add_scheduling_links()
#create_available_meals()

#console.log get_recrule_day_of_week_indexes([ 'RRULE:FREQ=WEEKLY;BYDAY=TU,TH' ]) # 2,4