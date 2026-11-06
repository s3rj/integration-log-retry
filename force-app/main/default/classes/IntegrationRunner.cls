/**
 * Runs one attempt for each log it is given: every callout first, then every piece of DML. A callout after
 * DML in the same transaction is an error ("uncommitted work pending"), so job handlers, which may update
 * records, only run once the last callout of the batch is done.
 */
public without sharing class IntegrationRunner {
    public class Outcome {
        public Integer succeeded = 0;
        public Integer failed = 0;
        public List<Id> retryIds = new List<Id>();
        /** Minutes until the earliest retry in retryIds is due. */
        public Integer retryDelayMinutes;
    }

    private class Attempt {
        Integration_Log__c log;
        IntegrationJob job;
        IntegrationSettings.Setting setting;
        HttpResponse response;
        Exception error;
        Long durationMs;
    }

    @TestVisible
    private static List<Integration_Failure__e> lastPublished = new List<Integration_Failure__e>();

    public static Outcome run(List<Id> logIds) {
        Outcome outcome = new Outcome();
        List<Integration_Log__c> logs = [
            SELECT Id, Integration__c, Operation__c, Status__c, Attempt__c, Max_Attempts__c, Record_Id__c, Job_Class__c, Job_Payload__c
            FROM Integration_Log__c
            WHERE Id IN :logIds AND Status__c IN :IntegrationLogs.ACTIVE_STATUSES
                AND (Next_Attempt_At__c = null OR Next_Attempt_At__c <= :System.now())
        ];
        if (logs.isEmpty()) {
            return outcome;
        }

        // Phase 1: callouts only.
        List<Attempt> attempts = new List<Attempt>();
        for (Integration_Log__c log : logs) {
            attempts.add(perform(log));
        }

        // Phase 2: classify, write the logs, publish failures, run handlers.
        List<Attempt> successes = new List<Attempt>();
        List<Attempt> failures = new List<Attempt>();
        List<Integration_Failure__e> events = new List<Integration_Failure__e>();
        for (Attempt attempt : attempts) {
            classify(attempt, outcome, successes, failures, events);
        }
        update logs;
        if (!events.isEmpty()) {
            lastPublished = events;
            EventBus.publish(events);
        }
        List<Integration_Log__c> touchedByHandlers = new List<Integration_Log__c>();
        for (Attempt attempt : successes) {
            runHandler(attempt, true, touchedByHandlers);
        }
        for (Attempt attempt : failures) {
            runHandler(attempt, false, touchedByHandlers);
        }
        if (!touchedByHandlers.isEmpty()) {
            update touchedByHandlers;
        }
        return outcome;
    }

    /**
     * Re-runs onSuccess for Handler Failed logs with the stored response and no new callout: the request reached
     * the other side once and must not be sent twice. Returns the resulting status per log.
     */
    public static Map<Id, String> rerunHandlers(List<Id> logIds) {
        Map<Id, String> outcomes = new Map<Id, String>();
        List<Integration_Log__c> logs = [
            SELECT Id, Integration__c, Operation__c, Status__c, Attempt__c, Max_Attempts__c, Record_Id__c, Job_Class__c, Job_Payload__c, HTTP_Status__c, Response_Body__c
            FROM Integration_Log__c
            WHERE Id IN :logIds AND Status__c = :IntegrationLogs.STATUS_HANDLER_FAILED
        ];
        for (Integration_Log__c log : logs) {
            try {
                IntegrationJob job = rebuild(log);
                HttpResponse response = new HttpResponse();
                response.setStatusCode(log.HTTP_Status__c == null ? 200 : log.HTTP_Status__c.intValue());
                if (log.Response_Body__c != null) {
                    response.setBody(log.Response_Body__c);
                }
                job.onSuccess(response, log);
                log.Status__c = IntegrationLogs.STATUS_SUCCEEDED;
                log.Error_Message__c = null;
            } catch (Exception e) {
                log.Error_Message__c = IntegrationLogs.clip('Handler failed again: ' + e.getTypeName() + ': ' + e.getMessage(), IntegrationLogs.ERROR_MAX);
            }
            outcomes.put(log.Id, log.Status__c);
        }
        update logs;
        return outcomes;
    }

    /** The job as it was enqueued, re-created from the log's class name and JSON payload. */
    public static IntegrationJob rebuild(Integration_Log__c log) {
        Type jobType = log.Job_Class__c == null ? null : Type.forName(log.Job_Class__c);
        if (jobType == null) {
            throw new IntegrationDispatcher.DispatchException('Job class not found: ' + log.Job_Class__c);
        }
        return (IntegrationJob) JSON.deserialize(log.Job_Payload__c, jobType);
    }

    private static Attempt perform(Integration_Log__c log) {
        Attempt attempt = new Attempt();
        attempt.log = log;
        attempt.setting = IntegrationSettings.get(log.Integration__c);
        try {
            attempt.job = rebuild(log);
            HttpRequest request = attempt.job.buildRequest(attempt.setting);
            request.setTimeout(attempt.setting.timeoutSeconds * 1000);
            log.Endpoint__c = IntegrationLogs.clip(request.getEndpoint(), IntegrationLogs.TEXT_MAX);
            log.HTTP_Method__c = IntegrationLogs.clip(request.getMethod(), 10);
            log.Request_Body__c = IntegrationLogs.clip(request.getBody(), IntegrationLogs.BODY_MAX);
            Long started = System.currentTimeMillis();
            attempt.response = new Http().send(request);
            attempt.durationMs = System.currentTimeMillis() - started;
        } catch (Exception e) {
            attempt.error = e;
        }
        return attempt;
    }

    private static void classify(Attempt attempt, Outcome outcome, List<Attempt> successes, List<Attempt> failures, List<Integration_Failure__e> events) {
        Integration_Log__c log = attempt.log;
        log.Attempt__c = (log.Attempt__c == null ? 0 : log.Attempt__c) + 1;
        log.Duration_ms__c = attempt.durationMs;
        Integer status = attempt.response == null ? null : attempt.response.getStatusCode();
        if (attempt.response != null) {
            log.HTTP_Status__c = status;
            log.Response_Body__c = IntegrationLogs.clip(attempt.response.getBody(), IntegrationLogs.BODY_MAX);
        }
        if (attempt.error == null && status != null && status >= 200 && status < 300) {
            log.Status__c = IntegrationLogs.STATUS_SUCCEEDED;
            log.Completed_At__c = System.now();
            log.Next_Attempt_At__c = null;
            log.Error_Message__c = null;
            outcome.succeeded++;
            successes.add(attempt);
            return;
        }
        String message = attempt.error != null
            ? attempt.error.getTypeName() + ': ' + attempt.error.getMessage()
            : 'HTTP ' + status + ' ' + attempt.response.getStatus();
        log.Error_Message__c = IntegrationLogs.clip(message, IntegrationLogs.ERROR_MAX);
        Boolean attemptsLeft = log.Max_Attempts__c != null && log.Attempt__c < log.Max_Attempts__c;
        if (isRetryable(attempt) && attemptsLeft) {
            Integer delay = IntegrationBackoff.delayMinutes(log.Attempt__c.intValue(), attempt.setting.baseDelayMinutes);
            log.Status__c = IntegrationLogs.STATUS_RETRYING;
            log.Next_Attempt_At__c = System.now().addMinutes(delay);
            outcome.retryIds.add(log.Id);
            outcome.retryDelayMinutes = outcome.retryDelayMinutes == null ? delay : Math.min(outcome.retryDelayMinutes, delay);
            return;
        }
        log.Status__c = IntegrationLogs.STATUS_FAILED;
        log.Completed_At__c = System.now();
        log.Next_Attempt_At__c = null;
        outcome.failed++;
        failures.add(attempt);
        events.add(new Integration_Failure__e(
            Integration__c = log.Integration__c,
            Operation__c = log.Operation__c,
            Log_Id__c = log.Id,
            Record_Id__c = log.Record_Id__c,
            Attempts__c = log.Attempt__c,
            Error__c = log.Error_Message__c
        ));
    }

    /** Callout exceptions (timeouts, DNS, TLS) retry; a broken job never does; the job may override the status-code policy. */
    private static Boolean isRetryable(Attempt attempt) {
        if (attempt.job == null) {
            return false;
        }
        if (attempt.error != null) {
            return attempt.error instanceof System.CalloutException;
        }
        Boolean jobVerdict = attempt.job.isRetryable(attempt.response);
        if (jobVerdict != null) {
            return jobVerdict;
        }
        return attempt.setting.retryableStatuses.contains(attempt.response.getStatusCode());
    }

    private static void runHandler(Attempt attempt, Boolean success, List<Integration_Log__c> touched) {
        if (attempt.job == null) {
            return;
        }
        try {
            if (success) {
                attempt.job.onSuccess(attempt.response, attempt.log);
            } else {
                attempt.job.onFailure(attempt.log);
            }
        } catch (Exception e) {
            attempt.log.Status__c = IntegrationLogs.STATUS_HANDLER_FAILED;
            attempt.log.Error_Message__c = IntegrationLogs.clip('Handler failed: ' + e.getTypeName() + ': ' + e.getMessage(), IntegrationLogs.ERROR_MAX);
            touched.add(attempt.log);
        }
    }
}
