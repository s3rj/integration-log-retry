// Schedule the retry sweeper: six hourly jobs ten minutes apart (Apex cron takes a single minute value). Run once per org.
//   sf apex run --target-org <org> --file scripts/apex/schedule-sweeper.apex
List<Id> cronIds = IntegrationRetrySweeper.schedule();
System.debug(LoggingLevel.INFO, 'Scheduled ' + cronIds.size() + ' "' + IntegrationRetrySweeper.JOB_NAME + '" jobs: ' + cronIds);
