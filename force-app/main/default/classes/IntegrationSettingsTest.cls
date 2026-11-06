@IsTest
private class IntegrationSettingsTest {
    @IsTest
    static void unknownIntegrationsGetDefaults() {
        IntegrationSettings.Setting setting = IntegrationSettings.get('Nope');

        Assert.areEqual('Nope', setting.name, 'name kept');
        Assert.areEqual(3, setting.maxAttempts, 'default attempts');
        Assert.areEqual(1, setting.baseDelayMinutes, 'default delay');
        Assert.areEqual(30, setting.timeoutSeconds, 'default timeout');
        Assert.isTrue(setting.retryableStatuses.contains(503), 'default retryable statuses');
        Assert.isFalse(setting.retryableStatuses.contains(400), '400 is not retryable by default');
        Assert.isTrue(setting.active, 'active by default');
        Assert.isNull(setting.endpoint, 'no endpoint');
    }

    @IsTest
    static void theShippedEchoSettingIsRead() {
        IntegrationSettings.Setting echo = IntegrationSettings.get('echo');

        Assert.areEqual('Echo', echo.name, 'case-insensitive lookup keeps the record name');
        Assert.areEqual('https://postman-echo.com/post', echo.endpoint, 'endpoint from metadata');
        Assert.areEqual(3, echo.maxAttempts, 'attempts from metadata');
        Assert.isTrue(echo.active, 'active');
    }

    @IsTest
    static void recordValuesAreBoundedAndBlanksFallBackToDefaults() {
        Integration_Setting__mdt record = new Integration_Setting__mdt(
            DeveloperName = 'Bounded',
            Max_Attempts__c = 0,
            Base_Delay_Minutes__c = null,
            Timeout_Seconds__c = 500,
            Retryable_Status_Codes__c = '429, 503',
            Active__c = false
        );

        IntegrationSettings.Setting setting = new IntegrationSettings.Setting(record);

        Assert.areEqual(3, setting.maxAttempts, 'zero attempts falls back to the default');
        Assert.areEqual(1, setting.baseDelayMinutes, 'blank delay falls back to the default');
        Assert.areEqual(120, setting.timeoutSeconds, 'timeout capped at the platform maximum');
        Assert.areEqual(new Set<Integer>{ 429, 503 }, setting.retryableStatuses, 'statuses parsed');
        Assert.isFalse(setting.active, 'inactive honoured');
    }

    @IsTest
    static void parseStatusesIgnoresJunk() {
        Assert.areEqual(new Set<Integer>{ 408, 429, 500 }, IntegrationSettings.parseStatuses('408, 429,abc,,500'), 'numbers only');
        Assert.isTrue(IntegrationSettings.parseStatuses('').isEmpty(), 'empty input');
    }

    @IsTest
    static void overridesWinInTests() {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'echo' => new IntegrationSettings.Setting('Echo').withMaxAttempts(9)
        };

        Assert.areEqual(9, IntegrationSettings.get('Echo').maxAttempts, 'override used');
        Assert.areEqual(3, IntegrationSettings.get('Other').maxAttempts, 'unlisted names still get defaults');
    }
}
