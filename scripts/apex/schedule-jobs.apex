// Schedule the two housekeeping jobs. Run once per org.
//   sf apex run --target-org <org> --file scripts/apex/schedule-jobs.apex
// Retry sweeper: six hourly jobs ten minutes apart (Apex cron takes a single minute value). Re-queues due retries
// and Queued logs whose queueable is gone.
// Log purge: daily at 02:00. Deletes finished logs past their integration's retention.
List<Id> sweeperIds = IntegrationRetrySweeper.schedule();
Id purgeId = IntegrationLogPurge.schedule();
System.debug(LoggingLevel.INFO, 'Scheduled ' + sweeperIds.size() + ' "' + IntegrationRetrySweeper.JOB_NAME + '" jobs and "' + IntegrationLogPurge.JOB_NAME + '" (' + purgeId + ').');
