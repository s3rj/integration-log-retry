@IsTest
private class IntegrationLogPurgeTest {
    private static Integration_Log__c log(String status, Integer completedDaysAgo) {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'test' => new IntegrationSettings.Setting('Test').withRetention(30, 90)
        };
        Integration_Log__c log = IntegrationLogs.newLog(new RecordingJob(null), IntegrationSettings.get('Test'));
        log.Status__c = status;
        log.Completed_At__c = completedDaysAgo == null ? null : System.now().addDays(-completedDaysAgo);
        return log;
    }

    @IsTest
    static void deletesFinishedLogsPastTheirOwnRetention() {
        List<Integration_Log__c> logs = new List<Integration_Log__c>{
            log('Succeeded', 31),
            log('Succeeded', 29),
            log('Failed', 60),
            log('Failed', 91),
            log('Handler Failed', 100),
            log('Queued', null),
            log('Retrying', null)
        };
        insert logs;

        Test.startTest();
        Database.executeBatch(new IntegrationLogPurge());
        Test.stopTest();

        Set<Id> remaining = new Map<Id, Integration_Log__c>([SELECT Id FROM Integration_Log__c WHERE Id IN :logs]).keySet();
        Assert.isFalse(remaining.contains(logs[0].Id), 'success older than 30 days deleted');
        Assert.isTrue(remaining.contains(logs[1].Id), 'recent success kept');
        Assert.isTrue(remaining.contains(logs[2].Id), 'failure kept for 90 days');
        Assert.isFalse(remaining.contains(logs[3].Id), 'failure older than 90 days deleted');
        Assert.isFalse(remaining.contains(logs[4].Id), 'handler failure older than 90 days deleted');
        Assert.isTrue(remaining.contains(logs[5].Id), 'queued work never purged');
        Assert.isTrue(remaining.contains(logs[6].Id), 'retrying work never purged');
    }

    @IsTest
    static void scheduledRunLaunchesTheBatch() {
        Integration_Log__c old = log('Succeeded', 400);
        insert old;

        Test.startTest();
        new IntegrationLogPurge().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c WHERE Id = :old.Id], 'purged');
    }

    @IsTest
    static void scheduleRegistersTheDailyJob() {
        Id cronId = IntegrationLogPurge.schedule();

        CronTrigger cron = [SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id = :cronId];
        Assert.areEqual('0 0 2 * * ?', cron.CronExpression, 'daily at 02:00');
        Assert.areEqual('Integration log purge', cron.CronJobDetail.Name, 'job name');
    }

    @IsTest
    static void expiryFollowsTheStatusAndTheIntegration() {
        Datetime now = System.now();
        Assert.isTrue(IntegrationLogPurge.isExpired(log('Succeeded', 31), now), 'success past 30 days');
        Assert.isFalse(IntegrationLogPurge.isExpired(log('Succeeded', 29), now), 'success within 30 days');
        Assert.isFalse(IntegrationLogPurge.isExpired(log('Failed', 31), now), 'failure within 90 days');
        Assert.isTrue(IntegrationLogPurge.isExpired(log('Failed', 91), now), 'failure past 90 days');
        Assert.isFalse(IntegrationLogPurge.isExpired(log('Failed', null), now), 'never completed, never expired');
        Assert.areEqual(30, IntegrationSettings.shortestRetentionDays(), 'horizon is the shortest retention');

        IntegrationSettings.overrides.put('fast', new IntegrationSettings.Setting('Fast').withRetention(7, 14));
        Assert.areEqual(7, IntegrationSettings.shortestRetentionDays(), 'horizon follows the shortest configured retention');
    }
}
