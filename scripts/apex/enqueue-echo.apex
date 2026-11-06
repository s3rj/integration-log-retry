// Queue one Echo job against the public echo service and print the log Id.
// Needs the Integration Log Admin permission set; the Postman_Echo remote site ships with the project.
//   sf apex run --target-org <org> --file scripts/apex/enqueue-echo.apex
Id logId = IntegrationDispatcher.enqueue(new EchoJob(UserInfo.getUserId(), 'hello from integration-log-retry'));
System.debug(LoggingLevel.INFO, 'Queued Integration Log ' + logId + '. Watch it on the Integration Logs tab.');
