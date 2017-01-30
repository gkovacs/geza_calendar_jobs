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

delete_passed_events = cfy ->*
  tokens = yield -> auth.authorize(it)
  #console.log tokens
  events = yield -> calendar.events.list {auth, calendarId}, {}, it
  event_list = events?0?items
  for evt in event_list
    if not evt?start?
      continue
    start_time = moment(new Date(evt.start.dateTime))
    if moment().add(1, 'hours') >= start_time
      # already passed
      eventId = evt.id
      yield -> calendar.events.delete {auth, calendarId, eventId}, it

delete_passed_events()
