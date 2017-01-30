# geza_calendar_scheduler

Uses the [Google Calendar API for NodeJS](http://google.github.io/google-api-nodejs-client/16.1.0/calendar.html) to make modifications to my calendars.

## Running Locally

First create a file `.getsecret.yaml` in the format described in [getsecret](https://github.com/gkovacs/getsecret) with `available_meals_calendar_id` set to the calendar ID, and `google_service_account` to the JSON for the [JWT Service Token](https://github.com/google/google-api-nodejs-client/#using-jwt-service-tokens).

Then install dependencies and run the app:

```bash
npm install -g lscbin livescript yarn
yarn
lscbin
./bin/app
```

## Running on Heroku

Use the [scheduler](https://elements.heroku.com/addons/scheduler) addon

Can do a one-time run with:

```bash
heroku --app gcalendar app
```
