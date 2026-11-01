using System;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;

public sealed class IosAvatarRenderingDiagnosticsTests
{
    private static Type Helper => Type.GetType(
        "Maaso.Avatar.IosAvatarRenderingDiagnosticLog, Assembly-CSharp", true);
    private string root;
    private string PathName => Path.Combine(root, "maaso-render-diagnostics/unity-rendering-v1.json");

    [SetUp]
    public void SetUp() => root = Path.Combine(Path.GetTempPath(), "maaso-render-test-" + Guid.NewGuid());

    [TearDown]
    public void TearDown()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static object Create(string eventName = "startup", string buildGuid = "build-A",
        string device = "Apple GPU", int width = 1179, int height = 2556,
        float widthScale = 1f, float heightScale = 1f) =>
        Helper.GetMethod("CreateEvent").Invoke(null, new object[] {
            new DateTime(2026, 10, 16, 12, 30, 0, DateTimeKind.Utc), eventName, buildGuid,
            "6000.5.2f1", "Metal", device, "MultiThreaded", width, height,
            widthScale, heightScale, true,
        });

    private bool Append(object value) => (bool)Helper.GetMethod("TryAppendCache")
        .Invoke(null, new[] { (object)root, value });

    private JObject Read()
    {
        using var input = new StringReader(File.ReadAllText(PathName));
        using var reader = new JsonTextReader(input) { DateParseHandling = DateParseHandling.None };
        return JObject.Load(reader);
    }

    [Test]
    public void SnapshotHasOnlyAllowlistedLocalDiagnosticFields()
    {
        Assert.That(Append(Create()), Is.True);
        JObject value = Read();
        Assert.That((int)value["schemaVersion"], Is.EqualTo(1));
        JObject entry = (JObject)((JArray)value["events"])[0];
        Assert.That(entry.Properties().Select(p => p.Name), Is.EquivalentTo(new[] {
            "utc", "eventName", "buildGuid", "unityVersion", "graphicsApi", "graphicsDeviceName",
            "observedRenderingThreadingMode", "screenWidthPixels", "screenHeightPixels",
            "dynamicResolutionWidthScale", "dynamicResolutionHeightScale", "appFocused",
        }));
        Assert.That((string)entry["utc"], Is.EqualTo("2026-10-16T12:30:00.0000000Z"));
        Assert.That((string)entry["observedRenderingThreadingMode"], Is.EqualTo("MultiThreaded"));
        Assert.That((int)entry["screenWidthPixels"], Is.EqualTo(1179));
        Assert.That((bool)entry["appFocused"], Is.True);
        Assert.That(File.ReadAllText(PathName), Does.Not.Contain(root));
    }

    [Test]
    public void AppendingAcrossLaunchesRetainsOnlyLatestTwelveEvents()
    {
        for (int i = 0; i < 30; i++)
            Assert.That(Append(Create(i % 2 == 0 ? "startup" : "foreground", "build-" + i)), Is.True);
        JArray entries = (JArray)Read()["events"];
        Assert.That(entries.Count, Is.EqualTo(12));
        Assert.That((string)entries[0]["buildGuid"], Is.EqualTo("build-18"));
        Assert.That((string)entries[11]["buildGuid"], Is.EqualTo("build-29"));
        Assert.That(new FileInfo(PathName).Length, Is.LessThanOrEqualTo(32768));
        Assert.That(File.Exists(PathName + ".tmp"), Is.False);
    }

    [Test]
    public void PayloadBoundsStringsNumbersAndNonFiniteScales()
    {
        Assert.That(Append(Create(buildGuid: new string('g', 10000),
            device: "Apple\n\0\ud800" + new string('x', 10000),
            width: int.MaxValue, height: -1, widthScale: float.NaN, heightScale: float.PositiveInfinity)), Is.True);
        JObject entry = (JObject)((JArray)Read()["events"])[0];
        Assert.That(((string)entry["buildGuid"]).Length, Is.EqualTo(64));
        string device = (string)entry["graphicsDeviceName"];
        Assert.That(device.Length, Is.EqualTo(128));
        Assert.That(device.Any(c => char.IsControl(c) || char.IsSurrogate(c)), Is.False);
        Assert.That((int)entry["screenWidthPixels"], Is.EqualTo(32768));
        Assert.That((int)entry["screenHeightPixels"], Is.Zero);
        Assert.That((float)entry["dynamicResolutionWidthScale"], Is.Zero);
        Assert.That((float)entry["dynamicResolutionHeightScale"], Is.Zero);
        Assert.That(new FileInfo(PathName).Length, Is.LessThanOrEqualTo(32768));
    }

    [TestCase("not json")]
    [TestCase("{\"schemaVersion\":999,\"events\":[]}")]
    public void InvalidPreviousPayloadIsReplacedWithoutFailure(string json)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName));
        File.WriteAllText(PathName, json);
        Assert.That(Append(Create()), Is.True);
        Assert.That(((JArray)Read()["events"]).Count, Is.EqualTo(1));
    }

    [Test]
    public void OversizedPriorFileIsNotReadAndUnknownFieldsAreNotRetained()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName));
        File.WriteAllText(PathName, new string('x', 32769));
        Assert.That(Append(Create()), Is.True);
        JObject prior = Read();
        prior["chat"] = "private input";
        ((JObject)((JArray)prior["events"])[0])["userId"] = "private account";
        File.WriteAllText(PathName, prior.ToString());
        Assert.That(Append(Create("focus_gained")), Is.True);
        Assert.That(File.ReadAllText(PathName), Does.Not.Contain("private"));
        Assert.That(((JArray)Read()["events"]).Count, Is.EqualTo(2));
    }

    [Test]
    public void UnknownEventsAndFileFailuresCannotEscapeOrCreateUserPayloads()
    {
        Assert.That(Create("arbitrary message"), Is.Null);
        Assert.That(Append(null), Is.False);
        Assert.That(Directory.Exists(root), Is.False);
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "maaso-render-diagnostics"), "blocks directory");
        Assert.DoesNotThrow(() => Assert.That(Append(Create()), Is.False));
        Assert.That(File.Exists(PathName), Is.False);
    }

    [Test]
    public void LifecycleHostDoesNotRegisterOrSampleInEditor()
    {
        Type host = Type.GetType("Maaso.Avatar.IosAvatarRenderingDiagnostics, Assembly-CSharp", true);
        string[] runtimeMethods = host.GetMethods(BindingFlags.DeclaredOnly | BindingFlags.Public |
            BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance).Select(m => m.Name).ToArray();
        Assert.That(runtimeMethods, Is.Empty, "Only the pure helper is active in Editor; no lifecycle/Update hook.");
    }
}
