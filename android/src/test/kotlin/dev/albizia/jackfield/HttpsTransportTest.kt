package dev.albizia.jackfield

import dev.albizia.jackfield.http.HttpRequest
import dev.albizia.jackfield.http.HttpsTransport
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Test
import javax.net.ssl.HttpsURLConnection
import kotlin.test.assertEquals

class HttpsTransportTest {
    @Test fun `real HTTPS sends bearer and idempotency headers and never follows redirect`() = runBlocking {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val previous = HttpsURLConnection.getDefaultSSLSocketFactory()
        try {
            HttpsURLConnection.setDefaultSSLSocketFactory(clientCertificates.sslSocketFactory())
            MockWebServer().use { server ->
                server.useHttps(serverCertificates.sslSocketFactory(), false)
                server.start()
                server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", server.url("/redirected")).addHeader("Retry-After", "120"))
                server.enqueue(MockResponse().setResponseCode(204))
                val outcome = HttpsTransport().send(HttpRequest(server.url("/callback").toString(), "test-only-token", "event-7", "{\"version\":1}"))
                assertEquals(302, outcome.status)
                assertEquals(120_000L, outcome.retryAfterMs)
                assertEquals(1, server.requestCount)
                val request = server.takeRequest()
                assertEquals("POST", request.method)
                assertEquals("/callback", request.path)
                assertEquals("Bearer test-only-token", request.getHeader("Authorization"))
                assertEquals("event-7", request.getHeader("Idempotency-Key"))
                assertEquals("application/json", request.getHeader("Content-Type"))
                assertEquals("{\"version\":1}", request.body.readUtf8())
            }
        } finally { HttpsURLConnection.setDefaultSSLSocketFactory(previous) }
    }
}
