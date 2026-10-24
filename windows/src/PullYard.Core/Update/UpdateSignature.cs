using Org.BouncyCastle.Math.EC.Rfc8032;
using PullYard.Core.Api;

namespace PullYard.Core.Update;

public static class UpdateSignature
{
    public const string PublicKey = "";

    public static string UnsignedMessage => $"The release has no signature, so {AppInfo.DisplayName} won't install it. Download it from the release page instead.";
    public static string BadSignatureMessage => $"The update's signature doesn't match. It may have been tampered with, so {AppInfo.DisplayName} didn't install it.";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    public static bool IsConfigured => IsConfiguredWith(PublicKey);

    public static bool IsConfiguredWith(string publicKey) => publicKey.Trim().Length > 0;

    public static async Task Verify(string file, string? signatureUrl, CancellationToken ct = default)
    {
        if (!IsConfigured) return;
        var signature = await FetchSignature(signatureUrl, ct).ConfigureAwait(false);
        var payload = await File.ReadAllBytesAsync(file, ct).ConfigureAwait(false);
        Check(signature, payload, PublicKey);
    }

    public static void Check(string? signature, byte[] payload, string publicKey)
    {
        if (!IsConfiguredWith(publicKey)) return;
        if (string.IsNullOrWhiteSpace(signature)) throw new UpdateException(UnsignedMessage);
        if (!IsValid(signature, payload, publicKey)) throw new UpdateException(BadSignatureMessage);
    }

    public static bool IsValid(string signature, byte[] payload, string publicKey)
    {
        byte[] key;
        byte[] sig;
        try
        {
            key = Convert.FromBase64String(publicKey.Trim());
            sig = Convert.FromBase64String(signature.Trim());
        }
        catch (FormatException)
        {
            return false;
        }
        if (key.Length != Ed25519.PublicKeySize || sig.Length != Ed25519.SignatureSize) return false;
        try
        {
            return Ed25519.Verify(sig, 0, key, 0, payload, 0, payload.Length);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static async Task<string> FetchSignature(string? url, CancellationToken ct)
    {
        if (url is null || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) throw new UpdateException(UnsignedMessage);
        using var req = new HttpRequestMessage(HttpMethod.Get, uri);
        req.Headers.UserAgent.ParseAdd(AppInfo.UserAgent);
        req.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
        HttpResponseMessage response;
        byte[] data;
        try
        {
            (response, data) = await RecordedHttp.Send(Http, req, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            throw new UpdateException(UnsignedMessage);
        }
        using var _ = response;
        if (!response.IsSuccessStatusCode) throw new UpdateException(UnsignedMessage);
        return System.Text.Encoding.UTF8.GetString(data).Trim();
    }
}
