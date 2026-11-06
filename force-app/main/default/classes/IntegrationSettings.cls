/**
 * Per-integration policy from Integration_Setting__mdt, with defaults for anything left blank or unconfigured.
 */
public with sharing class IntegrationSettings {
    public static final Integer DEFAULT_MAX_ATTEMPTS = 3;
    public static final Integer DEFAULT_BASE_DELAY_MINUTES = 1;
    public static final Integer DEFAULT_TIMEOUT_SECONDS = 30;
    public static final Integer DEFAULT_RETENTION_DAYS = 30;
    public static final Integer DEFAULT_FAILED_RETENTION_DAYS = 90;
    public static final Set<Integer> DEFAULT_RETRYABLE_STATUSES = new Set<Integer>{ 408, 429, 500, 502, 503, 504 };

    public class Setting {
        public String name { get; private set; }
        public Integer maxAttempts { get; private set; }
        public Integer baseDelayMinutes { get; private set; }
        public Integer timeoutSeconds { get; private set; }
        public String endpoint { get; private set; }
        public Set<Integer> retryableStatuses { get; private set; }
        public Boolean active { get; private set; }
        /** Days a Succeeded log is kept after completion. */
        public Integer retentionDays { get; private set; }
        /** Days a Failed or Handler Failed log is kept after completion. */
        public Integer failedRetentionDays { get; private set; }

        /** Defaults for an integration with no metadata record. */
        public Setting(String name) {
            this.name = name;
            this.maxAttempts = DEFAULT_MAX_ATTEMPTS;
            this.baseDelayMinutes = DEFAULT_BASE_DELAY_MINUTES;
            this.timeoutSeconds = DEFAULT_TIMEOUT_SECONDS;
            this.retryableStatuses = DEFAULT_RETRYABLE_STATUSES.clone();
            this.active = true;
            this.retentionDays = DEFAULT_RETENTION_DAYS;
            this.failedRetentionDays = DEFAULT_FAILED_RETENTION_DAYS;
        }

        public Setting(Integration_Setting__mdt record) {
            this(record.DeveloperName);
            if (record.Max_Attempts__c != null && record.Max_Attempts__c >= 1) {
                maxAttempts = record.Max_Attempts__c.intValue();
            }
            if (record.Base_Delay_Minutes__c != null && record.Base_Delay_Minutes__c >= 1) {
                baseDelayMinutes = record.Base_Delay_Minutes__c.intValue();
            }
            if (record.Timeout_Seconds__c != null && record.Timeout_Seconds__c >= 1) {
                timeoutSeconds = Math.min(record.Timeout_Seconds__c.intValue(), 120);
            }
            if (String.isNotBlank(record.Retryable_Status_Codes__c)) {
                retryableStatuses = parseStatuses(record.Retryable_Status_Codes__c);
            }
            if (record.Retention_Days__c != null && record.Retention_Days__c >= 1) {
                retentionDays = record.Retention_Days__c.intValue();
            }
            if (record.Failed_Retention_Days__c != null && record.Failed_Retention_Days__c >= 1) {
                failedRetentionDays = record.Failed_Retention_Days__c.intValue();
            }
            endpoint = record.Endpoint__c;
            active = record.Active__c;
        }

        /** Test and in-memory configuration. */
        public Setting withMaxAttempts(Integer value) {
            maxAttempts = value;
            return this;
        }

        public Setting withBaseDelayMinutes(Integer value) {
            baseDelayMinutes = value;
            return this;
        }

        public Setting withEndpoint(String value) {
            endpoint = value;
            return this;
        }

        public Setting withActive(Boolean value) {
            active = value;
            return this;
        }

        public Setting withRetention(Integer succeededDays, Integer failedDays) {
            retentionDays = succeededDays;
            failedRetentionDays = failedDays;
            return this;
        }
    }

    @TestVisible
    private static Map<String, Setting> overrides;
    private static Map<String, Setting> cache;

    /** The setting for an integration name (case-insensitive). Unconfigured names get defaults. */
    public static Setting get(String integrationName) {
        String key = integrationName == null ? '' : integrationName.toLowerCase();
        Map<String, Setting> settings = all();
        return settings.containsKey(key) ? settings.get(key) : new Setting(integrationName);
    }

    /** The shortest retention any integration uses, defaults included: the purge batch's query horizon. */
    public static Integer shortestRetentionDays() {
        Integer shortest = Math.min(DEFAULT_RETENTION_DAYS, DEFAULT_FAILED_RETENTION_DAYS);
        for (Setting setting : all().values()) {
            shortest = Math.min(shortest, Math.min(setting.retentionDays, setting.failedRetentionDays));
        }
        return shortest;
    }

    /** Parses "408, 429,500" into a set of status codes, ignoring anything that is not a number. */
    public static Set<Integer> parseStatuses(String csv) {
        Set<Integer> statuses = new Set<Integer>();
        for (String part : csv.split(',')) {
            String trimmed = part.trim();
            if (trimmed.isNumeric()) {
                statuses.add(Integer.valueOf(trimmed));
            }
        }
        return statuses;
    }

    private static Map<String, Setting> all() {
        if (overrides != null) {
            return overrides;
        }
        if (cache == null) {
            cache = new Map<String, Setting>();
            for (Integration_Setting__mdt record : [
                SELECT DeveloperName, Max_Attempts__c, Base_Delay_Minutes__c, Retryable_Status_Codes__c, Timeout_Seconds__c, Endpoint__c, Active__c,
                    Retention_Days__c, Failed_Retention_Days__c
                FROM Integration_Setting__mdt
                LIMIT 1000
            ]) {
                cache.put(record.DeveloperName.toLowerCase(), new Setting(record));
            }
        }
        return cache;
    }
}
