/**
 * The admin's "try again", from Apex, from Flow, or from the Retry button on an Integration Log:
 *   Failed          -> one more attempt, now (the endpoint is back, the data was fixed)
 *   Handler Failed  -> re-run the job's success handler with the stored response, without sending the request
 *                      again: it reached the other side once and must not arrive twice
 *   Retrying        -> attempt now instead of waiting for the backoff
 * Anything else is left alone and reported as skipped.
 */
public without sharing class IntegrationRetry {
    public static final String OUTCOME_REQUEUED = 'Requeued';

    public class Request {
        @InvocableVariable(label='Integration Log Id' required=true)
        public Id logId;
    }

    public class Result {
        @InvocableVariable(label='Outcome' description='Requeued, Succeeded, Handler Failed, or Skipped (<status>).')
        public String outcome;
    }

    @InvocableMethod(
        label='Retry integration logs'
        description='Failed: one more attempt now. Handler Failed: re-run the success handler with the stored response, without re-sending. Retrying: attempt now. Returns one outcome per log.'
        category='Integration Logs'
    )
    public static List<Result> retryFromFlow(List<Request> requests) {
        List<Id> logIds = new List<Id>();
        for (Request request : requests) {
            logIds.add(request.logId);
        }
        Map<Id, String> outcomes = retry(logIds);
        List<Result> results = new List<Result>();
        for (Id logId : logIds) {
            Result result = new Result();
            result.outcome = outcomes.containsKey(logId) ? outcomes.get(logId) : 'Skipped (not found)';
            results.add(result);
        }
        return results;
    }

    /** Outcome per log Id: Requeued, the handler re-run's resulting status, or Skipped (<status>). */
    public static Map<Id, String> retry(List<Id> logIds) {
        Map<Id, String> outcomes = new Map<Id, String>();
        List<Integration_Log__c> requeue = new List<Integration_Log__c>();
        List<Id> handlerReruns = new List<Id>();
        for (Integration_Log__c log : [SELECT Id, Status__c, Attempt__c, Max_Attempts__c FROM Integration_Log__c WHERE Id IN :logIds]) {
            if (log.Status__c == IntegrationLogs.STATUS_HANDLER_FAILED) {
                handlerReruns.add(log.Id);
            } else if (log.Status__c == IntegrationLogs.STATUS_FAILED || log.Status__c == IntegrationLogs.STATUS_RETRYING) {
                if (log.Status__c == IntegrationLogs.STATUS_FAILED) {
                    log.Max_Attempts__c = (log.Attempt__c == null ? 0 : log.Attempt__c) + 1; // exactly one more
                }
                log.Status__c = IntegrationLogs.STATUS_RETRYING;
                log.Next_Attempt_At__c = System.now();
                log.Completed_At__c = null;
                requeue.add(log);
                outcomes.put(log.Id, OUTCOME_REQUEUED);
            } else {
                outcomes.put(log.Id, 'Skipped (' + log.Status__c + ')');
            }
        }
        if (!requeue.isEmpty()) {
            update requeue;
            IntegrationQueueable.chain(new List<Id>(new Map<Id, Integration_Log__c>(requeue).keySet()), 0);
        }
        if (!handlerReruns.isEmpty()) {
            outcomes.putAll(IntegrationRunner.rerunHandlers(handlerReruns));
        }
        return outcomes;
    }
}
