package com.beachcheck.global.metrics;

import static org.assertj.core.api.Assertions.assertThat;

import com.beachcheck.support.config.FirebaseTestConfig;
import com.beachcheck.support.config.TestcontainersConfig;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = "management.server.port=0")
// 테스트는 기본으로 메트릭 exporter를 끄므로 Prometheus registry만 다시 켠다.
@AutoConfigureObservability(tracing = false)
@Import({TestcontainersConfig.class, FirebaseTestConfig.class})
@ActiveProfiles("test")
@DisplayName("Prometheus 메트릭 노출 계약")
class PrometheusEndpointIntegrationTest {

  private final HttpClient httpClient = HttpClient.newHttpClient();

  @LocalServerPort private int serverPort;
  @LocalManagementPort private int managementPort;

  @Test
  @DisplayName("management 포트에서 HTTP histogram과 JVM 지표를 Prometheus 형식으로 노출한다")
  void managementPort_exposesPrometheusMetrics() throws Exception {
    get(serverPort, "/api/beaches");

    HttpResponse<String> response = get(managementPort, "/actuator/prometheus");

    assertThat(response.statusCode()).isEqualTo(200);
    assertThat(response.body())
        .contains("http_server_requests_seconds_bucket{")
        .contains("application=\"beach\"")
        .contains("jvm_memory_used_bytes{");
  }

  @Test
  @DisplayName("애플리케이션 포트에서는 Prometheus 메트릭을 노출하지 않는다")
  void applicationPort_doesNotExposePrometheusMetrics() throws Exception {
    HttpResponse<String> response = get(serverPort, "/actuator/prometheus");

    assertThat(response.statusCode()).isNotEqualTo(200);
    assertThat(response.body()).doesNotContain("jvm_memory_used_bytes");
  }

  private HttpResponse<String> get(int port, String path) throws Exception {
    HttpRequest request =
        HttpRequest.newBuilder(URI.create("http://localhost:" + port + path)).GET().build();
    return httpClient.send(request, HttpResponse.BodyHandlers.ofString());
  }
}
