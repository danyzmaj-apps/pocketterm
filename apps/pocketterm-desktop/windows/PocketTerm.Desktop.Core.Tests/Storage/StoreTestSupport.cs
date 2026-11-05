using System.Security.Cryptography;

// Its own namespace: other slices' test helpers may share these names.
namespace PocketTerm.Desktop.Tests.Store;

/// <summary>A test that needs Windows itself (DPAPI, the registry): skipped elsewhere.</summary>
internal sealed class StoreWindowsFactAttribute : FactAttribute
{
    public StoreWindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "Windows only";
    }
}

/// <summary>A test that needs a POSIX system (symlinks, chmod, /bin/sh scripts): skipped on Windows.</summary>
internal sealed class StorePosixFactAttribute : FactAttribute
{
    public StorePosixFactAttribute()
    {
        if (OperatingSystem.IsWindows()) Skip = "POSIX only";
    }
}

/// <summary>
/// DPAPI's stand-in off Windows: a marker and the bytes XORed, so a file it seals isn't plain text and
/// one it didn't seal fails to open as DPAPI's would. <see cref="FailNext"/> fails the next seal; <see cref="Delay"/>
/// slows each seal, so writes that aren't one at a time would overlap.
/// </summary>
internal sealed class FakeProtector : ISecretProtector
{
    private static readonly byte[] Marker = "SEAL"u8.ToArray();

    public bool FailNext { get; set; }

    public TimeSpan Delay { get; set; }

    public byte[] Protect(byte[] plain)
    {
        if (Delay > TimeSpan.Zero) Thread.Sleep(Delay);
        if (FailNext)
        {
            FailNext = false;
            throw new CryptographicException("locked");
        }
        return [.. Marker, .. plain.Select(b => (byte)(b ^ 0x5A))];
    }

    public byte[] Unprotect(byte[] sealedBytes)
    {
        if (sealedBytes.Length < Marker.Length || !sealedBytes.AsSpan(0, Marker.Length).SequenceEqual(Marker))
        {
            throw new CryptographicException("The data is invalid.");
        }
        return sealedBytes.Skip(Marker.Length).Select(b => (byte)(b ^ 0x5A)).ToArray();
    }
}

/// <summary>A folder of its own under the temp folder, gone again at the end.</summary>
internal sealed class TempDir : IDisposable
{
    public string Path { get; } = Directory.CreateTempSubdirectory("pocketterm-store").FullName;

    public string this[string name] => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
