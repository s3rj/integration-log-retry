@IsTest
private class IntegrationBackoffTest {
    @IsTest
    static void delaysDoubleWithEachAttempt() {
        Assert.areEqual(1, IntegrationBackoff.delayMinutes(1, 1), 'after the first attempt');
        Assert.areEqual(2, IntegrationBackoff.delayMinutes(2, 1), 'after the second');
        Assert.areEqual(4, IntegrationBackoff.delayMinutes(3, 1), 'after the third');
        Assert.areEqual(40, IntegrationBackoff.delayMinutes(4, 5), 'base of five');
    }

    @IsTest
    static void delaysAreCappedAtADay() {
        Assert.areEqual(1440, IntegrationBackoff.delayMinutes(20, 5), 'capped');
    }

    @IsTest
    static void badInputsFallBackToTheFirstAttemptAndABaseOfOne() {
        Assert.areEqual(1, IntegrationBackoff.delayMinutes(null, null), 'nulls');
        Assert.areEqual(1, IntegrationBackoff.delayMinutes(0, 0), 'zeros');
    }

    @IsTest
    static void enqueueDelayIsCappedAtTenMinutes() {
        Assert.areEqual(0, IntegrationBackoff.enqueueDelay(0), 'zero');
        Assert.areEqual(4, IntegrationBackoff.enqueueDelay(4), 'under the cap');
        Assert.areEqual(10, IntegrationBackoff.enqueueDelay(40), 'capped');
        Assert.areEqual(0, IntegrationBackoff.enqueueDelay(null), 'null');
    }
}
