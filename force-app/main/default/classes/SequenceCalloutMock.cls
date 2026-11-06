/**
 * Test double: answers callouts from a script of HTTP status codes (Integer) or exceptions to throw, repeating
 * the last entry once the script runs out, and keeps every request it saw.
 */
@IsTest
public class SequenceCalloutMock implements HttpCalloutMock {
    public List<HttpRequest> requests = new List<HttpRequest>();
    private final List<Object> script;
    private Integer cursor = 0;

    public SequenceCalloutMock(List<Object> script) {
        this.script = script;
    }

    public static SequenceCalloutMock always(Integer status) {
        return new SequenceCalloutMock(new List<Object>{ status });
    }

    public HttpResponse respond(HttpRequest request) {
        requests.add(request);
        Object step = script[Math.min(cursor, script.size() - 1)];
        cursor++;
        if (step instanceof Exception) {
            throw (Exception) step;
        }
        Integer status = (Integer) step;
        HttpResponse response = new HttpResponse();
        response.setStatusCode(status);
        response.setStatus(status < 300 ? 'OK' : 'Error');
        response.setBody('{"status":' + status + ',"echo":' + (request.getBody() == null ? 'null' : request.getBody()) + '}');
        return response;
    }
}
