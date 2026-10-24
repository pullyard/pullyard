using System.Text;
using Org.BouncyCastle.Math.EC.Rfc8032;
using PullYard.Core.Update;
using Xunit;

namespace PullYard.Core.Tests;

public class UpdateSignatureTests
{
    private const string Rfc8032Key = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    private const string Rfc8032Signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
    private const string Rfc8032Key2 = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
    private const string Rfc8032Signature2 = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";

    private static string B64(string hex) => Convert.ToBase64String(Convert.FromHexString(hex));

    [Fact]
    public void AcceptsRfc8032Vectors()
    {
        Assert.True(UpdateSignature.IsValid(B64(Rfc8032Signature), Array.Empty<byte>(), B64(Rfc8032Key)));
        Assert.True(UpdateSignature.IsValid(B64(Rfc8032Signature2) + "\n", new byte[] { 0x72 }, B64(Rfc8032Key2)));
    }

    [Fact]
    public void RejectsTamperedPayloadOrWrongKey()
    {
        Assert.False(UpdateSignature.IsValid(B64(Rfc8032Signature2), new byte[] { 0x73 }, B64(Rfc8032Key2)));
        Assert.False(UpdateSignature.IsValid(B64(Rfc8032Signature2), new byte[] { 0x72 }, B64(Rfc8032Key)));
        var flipped = Convert.FromHexString(Rfc8032Signature2);
        flipped[10] ^= 1;
        Assert.False(UpdateSignature.IsValid(Convert.ToBase64String(flipped), new byte[] { 0x72 }, B64(Rfc8032Key2)));
    }

    [Fact]
    public void RejectsMalformedInput()
    {
        Assert.False(UpdateSignature.IsValid("not base64!", new byte[] { 0x72 }, B64(Rfc8032Key2)));
        Assert.False(UpdateSignature.IsValid(B64(Rfc8032Signature2), new byte[] { 0x72 }, "%%%"));
        Assert.False(UpdateSignature.IsValid(Convert.ToBase64String(new byte[10]), new byte[] { 0x72 }, B64(Rfc8032Key2)));
        Assert.False(UpdateSignature.IsValid(B64(Rfc8032Signature2), new byte[] { 0x72 }, Convert.ToBase64String(new byte[16])));
    }

    [Fact]
    public void VerifiesAGeneratedKeypair()
    {
        var secret = new byte[Ed25519.SecretKeySize];
        Ed25519.GeneratePrivateKey(new Org.BouncyCastle.Security.SecureRandom(), secret);
        var publicKey = new byte[Ed25519.PublicKeySize];
        Ed25519.GeneratePublicKey(secret, 0, publicKey, 0);
        var payload = Encoding.UTF8.GetBytes(new string('x', 200_000));
        var sig = new byte[Ed25519.SignatureSize];
        Ed25519.Sign(secret, 0, payload, 0, payload.Length, sig, 0);
        var key = Convert.ToBase64String(publicKey);
        UpdateSignature.Check(Convert.ToBase64String(sig), payload, key);
        payload[^1] = (byte)'y';
        var e = Assert.Throws<UpdateException>(() => UpdateSignature.Check(Convert.ToBase64String(sig), payload, key));
        Assert.Equal(UpdateSignature.BadSignatureMessage, e.Message);
    }

    [Fact]
    public void MissingSignatureFailsOnlyWhenAKeyIsSet()
    {
        var e = Assert.Throws<UpdateException>(() => UpdateSignature.Check(null, new byte[] { 1 }, B64(Rfc8032Key)));
        Assert.Equal(UpdateSignature.UnsignedMessage, e.Message);
        Assert.Throws<UpdateException>(() => UpdateSignature.Check("  ", new byte[] { 1 }, B64(Rfc8032Key)));
        UpdateSignature.Check(null, new byte[] { 1 }, "");
        UpdateSignature.Check("garbage", new byte[] { 1 }, " ");
    }

    [Fact]
    public async Task ShippedKeyIsValidAndRequiresASignature()
    {
        Assert.True(UpdateSignature.IsConfigured);
        Assert.Equal(32, Convert.FromBase64String(UpdateSignature.PublicKey).Length);
        Assert.False(UpdateSignature.IsConfiguredWith(""));
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        await File.WriteAllBytesAsync(file, new byte[] { 1, 2, 3 });
        var error = await Assert.ThrowsAnyAsync<Exception>(() => UpdateSignature.Verify(file, null));
        Assert.Equal(UpdateSignature.UnsignedMessage, error.Message);
        File.Delete(file);
    }

    [Fact]
    public void ParsesSignatureAsset()
    {
        var installer = AppInfo.InstallerAssetName("x64");
        var json = $$"""
        {"tag_name":"v2.6.0","name":"","body":"","html_url":"https://example.com/r",
         "assets":[{"name":"{{installer}}","browser_download_url":"https://example.com/x64.exe","size":1234},
                   {"name":"{{installer}}.sig","browser_download_url":"https://example.com/x64.exe.sig","size":89}]}
        """;
        Assert.Equal("https://example.com/x64.exe.sig", Releases.Parse(json, "x64").SignatureUrl);
        Assert.Null(Releases.Parse(json.Replace(".sig", ".txt"), "x64").SignatureUrl);
    }
}
