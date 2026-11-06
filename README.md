# integration-log-retry

A small framework for outbound Salesforce integrations that fail for boring reasons: a log record per unit of work, bulk-safe queueable execution, exponential-backoff retries, a platform event when work stops for good, and a scheduled sweeper so nothing is ever stranded.

Most orgs call out from a trigger or a flow, catch the exception, and hope. When the endpoint returns a 503 at 2 a.m., the record is silently never sent, and someone writes a "re-run the sync" script three months later. This project replaces that with a pattern I have run in production: **log first, then queue, then retry with a memory.**

## How it works

```
IntegrationDispatcher.enqueue(job)
   │  inserts Integration_Log__c (Queued) holding the job as JSON
   ▼
IntegrationQueueable (10 logs per execution)
   │  all callouts first ──► IntegrationRunner.run()
   │  then all DML: log outcome, publish failures, run job handlers
   ├─ leftovers ─────────────► chain immediately
   ├─ retryable failures ────► Retrying + Next Attempt At, chain with backoff (≤10 min)
   └─ exhausted / non-retryable ► Failed + Integration_Failure__e
IntegrationRetrySweeper (every 10 minutes)
      re-queues Retrying logs that are due, including any whose chain was lost
```

- **The log is the unit of work.** `Integration_Log__c` stores the job's class and JSON state, so every attempt re-creates the job fresh (new tokens, current timestamps) and a retry survives the end of the transaction, the flex queue, and a lost chain.
- **Callouts before DML.** A callout after DML in the same transaction fails with "uncommitted work pending", so the runner performs every callout in the batch first and only then writes logs and runs handlers, which are free to update records.
- **Retry policy lives in metadata.** `Integration_Setting__mdt` per integration: max attempts, base delay, retryable status codes, timeout, endpoint. Callout exceptions (timeouts, DNS, TLS) always retry; a job can veto or force a retry for a specific response.
- **Exponential backoff** doubles the base delay after every failed attempt. The queueable delay is capped at the platform's ten minutes; later retries are the sweeper's job.
- **Idempotent enqueueing.** A job may return a dedup key; while a log with that key is active, enqueueing the same key returns that log instead of creating a second one. Triggers that fire twice stop sending twice.
- **Failure is an event.** When work stops for good, the runner publishes `Integration_Failure__e` (integration, operation, log, record, attempts, error). Subscribe from Flow to post to Slack, open a case, or flag the record.
- **A Finalizer for the failures you cannot catch.** If a queueable dies from a limit exception, its transaction rolls back and nothing would be recorded. The attached `Recovery` finalizer counts the attempt, records the reason, and schedules the retry.

## Write a job

```apex
public with sharing class SendOrderJob extends IntegrationJobBase {
    public Id orderId;                 // public fields are serialized; keep them small

    public SendOrderJob() { super(); } // required: jobs are re-created from JSON
    public SendOrderJob(Id orderId) { this.orderId = orderId; }

    public override String integrationName() { return 'ERP'; }          // Integration_Setting__mdt.ERP
    public override String operation() { return 'send-order'; }
    public override String dedupKey() { return 'order:' + orderId; }     // one active send per order
    public override Id recordId() { return orderId; }

    public override HttpRequest buildRequest(IntegrationSettings.Setting setting) {
        Order__c order = [SELECT Name, Total__c FROM Order__c WHERE Id = :orderId];
        HttpRequest request = new HttpRequest();
        request.setEndpoint(setting.endpoint + '/orders');             // e.g. callout:ERP/api/v1
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(new Map<String, Object>{ 'name' => order.Name, 'total' => order.Total__c }));
        return request;
    }

    public override void onSuccess(HttpResponse response, Integration_Log__c log) {
        String erpId = (String) ((Map<String, Object>) JSON.deserializeUntyped(response.getBody())).get('id');
        update new Order__c(Id = orderId, ERP_Id__c = erpId, Last_Synced_At__c = System.now());
    }
}
```

Queue it from a trigger handler, a flow-invoked Apex action, or anonymous Apex:

```apex
IntegrationDispatcher.enqueueAll(jobsForChangedOrders);   // one transaction, one queueable
```

Rules for jobs: a public no-argument constructor, JSON-serializable public fields, and no DML in `buildRequest`. Everything else is optional; `IntegrationJobBase` supplies defaults.

## Configure an integration

| `Integration_Setting__mdt` field | Meaning | Default |
|---|---|---|
| Developer Name | What `integrationName()` returns | |
| Max Attempts | Total attempts including the first | 3 |
| Base Delay (minutes) | Wait after the first failure; doubles each time | 1 |
| Retryable Status Codes | Comma-separated HTTP statuses that retry | 408, 429, 500, 502, 503, 504 |
| Timeout (seconds) | Applied to every attempt (max 120) | 30 |
| Endpoint | Handed to `buildRequest`; use a named credential (`callout:Name/path`) | |
| Active | Unchecked: `enqueue()` throws instead of queueing | checked |

Max attempts are copied onto each log when it is created, so changing a setting never alters work already in flight.

## Install and try it

```bash
sf project deploy start --target-org <org>
sf org assign permset --name Integration_Log_Admin --target-org <org>
sf apex run --target-org <org> --file scripts/apex/schedule-sweeper.apex   # once per org: six hourly jobs, ten minutes apart
sf apex run --target-org <org> --file scripts/apex/enqueue-echo.apex       # a real callout to postman-echo.com
sf data query --target-org <org> --file scripts/soql/recent-logs.soql
```

The sample `EchoJob` and its `Echo` setting (plus a remote site for postman-echo.com) show a log going Queued to Succeeded against a live endpoint. Delete them once you have real jobs.

## Log statuses

| Status | Meaning |
|---|---|
| Queued | Logged, waiting for its first attempt |
| Retrying | A retryable failure; `Next Attempt At` says when |
| Succeeded | 2xx response; `onSuccess` ran |
| Failed | Retries exhausted, a non-retryable response, or a job that could not be built; `Integration_Failure__e` published; `onFailure` ran |
| Handler Failed | The callout succeeded but `onSuccess` threw; the response is kept so the handler can be fixed and re-run by hand |

## Limits and trade-offs

- **One callout per log, ten logs per queueable execution.** Enough for most record-level integrations; a bulk endpoint needs a job that batches records itself.
- **No "Running" status.** Marking a log Running would be DML before the callout, which the platform forbids in one transaction. Duration and timestamps are written afterwards instead.
- **Handlers run after the whole batch's callouts.** `onSuccess` for log 1 runs after the callout for log 10, so handlers should not assume they run immediately.
- **The ten-minute enqueue cap** means a third retry at 4× base delay may wait for the sweeper. Schedule it.
- **Job payloads are stored as text** on the log (up to 128 KB). Keep IDs in the job and query the data in `buildRequest`; it keeps logs small and attempts current.
- **Inbound** webhooks are a different problem (signatures, replay protection, idempotent handlers); see the companion `hmac-webhook-receiver`.

## Development

```bash
scripts/validate.sh <org alias>                       # deploy and run all local tests with coverage
pmd check -d force-app -R pmd/ruleset.xml -f text     # static analysis, same ruleset as CI
```

Validated in a Developer Edition org on API 68.0: 38 tests, 100% coverage on every class but one (98%), and a live `EchoJob` run that logged HTTP 200 from postman-echo.com in 98 ms.

Tests use `SequenceCalloutMock` (scripted status codes or exceptions) and `RecordingJob` (a job that can be told to misbehave). Logs are inserted before `Test.startTest()` and the runner is called once inside it, because a callout after DML in one transaction is an error, which is also why the runner never runs in the enqueueing transaction. Chaining is recorded rather than executed in tests, where only one queueable may run; the `Recovery` finalizer is exercised directly with a stub `FinalizerContext`.

## License

MIT
