using System;
using System.Collections;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

public sealed class CompanionPortalLayerTests
{
    private static Type AvatarType(string name) =>
        Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    private static object Call(object target, string name, params object[] arguments) =>
        target.GetType().GetMethod(name,
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Invoke(target, arguments);

    private static void Set(object target, string name, object value) =>
        target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)
            .SetValue(target, value);

    private static T Field<T>(object target, string name) =>
        (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)
            .GetValue(target);

    [Test]
    public void SceneCaptureUsesActualCameraAndRestoresItBeforeAvatarOnlyCapture()
    {
        using var f = new Fixture();
        var previousTarget = new RenderTexture(64, 64, 16);
        GameObject room = f.Part(null, "Room surface", 0);
        Component depthOfField = f.Camera.gameObject.AddComponent(AvatarType("PortraitDepthOfField"));
        f.Camera.fieldOfView = 43f;
        f.Camera.aspect = 1.25f;
        f.Camera.targetTexture = previousTarget;
        f.Camera.backgroundColor = Color.gray;
        f.Camera.enabled = false;
        try
        {
            Call(f.Portal, "OnAvatarPortalCommand",
                "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactHigh\",\"targetFps\":30," +
                "\"includeWorld\":true,\"viewportWidth\":1080,\"viewportHeight\":720}");
            Assert.That(Field<Camera>(f.Portal, "portalCamera"), Is.SameAs(f.Camera),
                "The complete scene must include the real camera's image effects and World updates.");
            Assert.That(f.Camera.GetComponent(AvatarType("PortraitDepthOfField")), Is.SameAs(depthOfField));
            Assert.That(f.Camera.enabled, Is.True, "Acquiring a scene must resume a previously paused source camera.");
            Assert.That(f.Camera.targetTexture.width, Is.EqualTo(1080));
            Assert.That(f.Camera.targetTexture.height, Is.EqualTo(720));
            Assert.That(f.Camera.aspect, Is.EqualTo(1.5f));
            Assert.That(f.Camera.fieldOfView, Is.EqualTo(43f));
            Assert.That(f.Camera.cullingMask, Is.EqualTo(f.AuthoredCameraMask));
            Assert.That(f.Camera.cullingMask & (1 << room.layer), Is.Not.Zero);
            Assert.That(f.Root.layer, Is.EqualTo(8));
            Assert.That(f.Body.layer, Is.EqualTo(9));

            Set(f.Receiver, "avatarLeasedToWorld", true);
            f.Camera.fieldOfView = 57f;
            f.Camera.transform.position = new Vector3(2f, 3f, 4f);
            f.Frame();
            Assert.That(f.Portal.GetType().GetProperty("IsAcquired").GetValue(f.Portal), Is.True);
            Assert.That(f.Camera.fieldOfView, Is.EqualTo(57f));
            Assert.That(f.Camera.transform.position, Is.EqualTo(new Vector3(2f, 3f, 4f)));
            Call(f.Portal, "Suspend", 1);
            Assert.That(f.Camera.enabled, Is.False);
            Call(f.Portal, "Resume", 1);
            Assert.That(f.Camera.enabled, Is.True, "Scene capture remains available while World owns the avatar.");
            f.Release(1);
            Assert.That(f.Camera.targetTexture, Is.SameAs(previousTarget));
            Assert.That(f.Camera.aspect, Is.EqualTo(1.25f));
            Assert.That(f.Camera.enabled, Is.False, "Release restores the source camera's original paused state.");
            Assert.That(f.Camera.cullingMask, Is.EqualTo(f.AuthoredCameraMask));

            Set(f.Receiver, "avatarLeasedToWorld", false);
            f.Camera.enabled = true;
            f.Acquire(2);
            Camera avatarCamera = Field<Camera>(f.Portal, "portalCamera");
            Assert.That(avatarCamera, Is.Not.SameAs(f.Camera));
            Assert.That(avatarCamera.fieldOfView, Is.EqualTo(28f));
            Assert.That(avatarCamera.aspect, Is.EqualTo(240f / 416f).Within(.00001f));
            Assert.That(avatarCamera.backgroundColor.a, Is.Zero);
            Assert.That(avatarCamera.cullingMask, Is.EqualTo(1 << f.CaptureLayer));
            Assert.That(f.Body.layer, Is.EqualTo(f.CaptureLayer));
            f.Release(2);
            Assert.That(f.Body.layer, Is.EqualTo(9));
        }
        finally
        {
            f.Release(0);
            f.Camera.targetTexture = null;
            Object.DestroyImmediate(previousTarget);
            Object.DestroyImmediate(room);
        }
    }

    [Test]
    public void SceneToLegacyCapturePreservesSquarePixelsAtEveryProfile(
        [Values(4f / 3f, 16f / 9f, 390f / 844f)] float sourceAspect,
        [Values("compactLow", "compactBalanced", "compactHigh", "desktopHigh")] string profile)
    {
        using var f = new Fixture();
        f.Camera.aspect = sourceAspect;
        f.Body.transform.localScale = Vector3.one * .25f;
        Shader shader = Shader.Find("Unlit/Color");
        Assert.That(shader, Is.Not.Null);
        var material = new Material(shader) { color = Color.white };
        f.Body.GetComponent<Renderer>().sharedMaterial = material;
        Texture2D pixels = null;
        RenderTexture previousActive = RenderTexture.active;
        try
        {
            Call(f.Portal, "OnAvatarPortalCommand",
                "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactHigh\",\"targetFps\":30," +
                "\"includeWorld\":true,\"viewportWidth\":1080,\"viewportHeight\":720}");
            f.Release(1);
            Assert.That(f.Camera.aspect, Is.EqualTo(sourceAspect).Within(.00001f));

            Call(f.Portal, "Acquire", 2, profile, 30);
            Camera camera = Field<Camera>(f.Portal, "portalCamera");
            RenderTexture texture = camera.targetTexture;
            int width = profile == "compactLow" ? 240 : profile == "compactBalanced" ? 288 :
                profile == "desktopHigh" ? 1024 : 320;
            int height = profile == "compactLow" ? 416 : profile == "compactBalanced" ? 496 :
                profile == "desktopHigh" ? 1792 : 560;
            Assert.That(texture.width, Is.EqualTo(width));
            Assert.That(texture.height, Is.EqualTo(height));
            Assert.That(camera.aspect, Is.EqualTo((float)width / height).Within(.00001f));
            Assert.That(f.Camera.aspect, Is.EqualTo(sourceAspect).Within(.00001f),
                "Fix only the portrait clone; preserve the source camera restoration contract.");
            Assert.That(camera.fieldOfView, Is.EqualTo(28f));
            Assert.That(camera.backgroundColor.a, Is.Zero);

            Vector3 center = f.Body.transform.position - Vector3.forward * .125f;
            Vector3 left = camera.WorldToViewportPoint(center - Vector3.right * .125f);
            Vector3 right = camera.WorldToViewportPoint(center + Vector3.right * .125f);
            Vector3 bottom = camera.WorldToViewportPoint(center - Vector3.up * .125f);
            Vector3 top = camera.WorldToViewportPoint(center + Vector3.up * .125f);
            float projectedRatio = (right.x - left.x) * width / ((top.y - bottom.y) * height);
            Assert.That(projectedRatio, Is.EqualTo(1f).Within(.001f));

            camera.Render();
            RenderTexture.active = texture;
            pixels = new Texture2D(width, height, TextureFormat.RGBA32, false, false);
            pixels.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            pixels.Apply();
            Color32[] colors = pixels.GetPixels32();
            int minX = width, minY = height, maxX = -1, maxY = -1;
            for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                if (colors[y * width + x].a < 128) continue;
                minX = Math.Min(minX, x); maxX = Math.Max(maxX, x);
                minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
            }
            Assert.That(maxX - minX, Is.GreaterThan(width * .25f));
            Assert.That(minX, Is.GreaterThan(1));
            Assert.That(maxX, Is.LessThan(width - 2), "The square must not pass by clipping its sides.");
            Assert.That(minY, Is.GreaterThan(1));
            Assert.That(maxY, Is.LessThan(height - 2));
            Assert.That((float)(maxX - minX + 1) / (maxY - minY + 1),
                Is.EqualTo(1f).Within(.02f), "Rendered pixels must retain the square's physical proportions.");
            TestContext.Out.WriteLine($"sourceAspect={sourceAspect:F6}, profile={profile}, " +
                $"texture={width}x{height}, projection={projectedRatio:F6}, " +
                $"opaqueBounds={maxX - minX + 1}x{maxY - minY + 1}");
            f.Release(2);
            Assert.That(f.Camera.aspect, Is.EqualTo(sourceAspect).Within(.00001f));
        }
        finally
        {
            RenderTexture.active = previousActive;
            if (pixels != null) Object.DestroyImmediate(pixels);
            Object.DestroyImmediate(material);
        }
    }

    [Test]
    public void SceneCaptureSubmitsAfterEndOfFrameAndRequiresAFreshRenderedFrame()
    {
        using var f = new Fixture();
        Call(f.Portal, "OnAvatarPortalCommand",
            "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactHigh\",\"targetFps\":30," +
            "\"includeWorld\":true,\"viewportWidth\":390,\"viewportHeight\":844}");
        var submissions = (IEnumerator)Call(f.Portal, "SubmitSceneFramesAfterRendering");
        Assert.That(submissions.MoveNext(), Is.True);
        Assert.That(submissions.Current, Is.TypeOf<WaitForEndOfFrame>());
        object cachedYield = submissions.Current;
        Call(f.Portal, "HandleCameraPostRender", f.Camera);
        Assert.That(Field<bool>(f.Portal, "didReportRenderedFrame"), Is.False,
            "The camera callback must leave time for OnRenderImage to finish.");
        Assert.That(submissions.MoveNext(), Is.True);
        Assert.That(submissions.Current, Is.SameAs(cachedYield));
        Assert.That(Field<bool>(f.Portal, "didReportRenderedFrame"), Is.True);
        Assert.That(Field<int>(f.Portal, "sceneRenderedFrame"), Is.EqualTo(-1));

        Set(f.Portal, "didReportRenderedFrame", false);
        Set(f.Portal, "lastSubmittedAtSeconds", double.NegativeInfinity);
        Assert.That(submissions.MoveNext(), Is.True);
        Assert.That(Field<bool>(f.Portal, "didReportRenderedFrame"), Is.False,
            "A stale target cannot be submitted without a new source-camera render.");
        Call(f.Portal, "HandleCameraPostRender", f.Camera);
        Call(f.Portal, "Suspend", 1);
        Call(f.Portal, "Resume", 1);
        Assert.That(submissions.MoveNext(), Is.True);
        Assert.That(Field<bool>(f.Portal, "didReportRenderedFrame"), Is.False,
            "Suspend discards pending frames even when resumed in the same frame.");
        f.Release(1);
        Assert.That(submissions.MoveNext(), Is.False);

        f.Acquire(2);
        Call(f.Portal, "HandleCameraPostRender", Field<Camera>(f.Portal, "portalCamera"));
        Assert.That(Field<bool>(f.Portal, "didReportRenderedFrame"), Is.True,
            "The existing avatar-only callback remains immediate.");
    }

    [Test]
    public void SceneCaptureCanStartAfterAvatarWasLeasedToWorld()
    {
        using var f = new Fixture();
        Set(f.Receiver, "avatarLeasedToWorld", true);
        Call(f.Portal, "OnAvatarPortalCommand",
            "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactHigh\",\"targetFps\":30," +
            "\"includeWorld\":true,\"viewportWidth\":390,\"viewportHeight\":844}");
        Assert.That(f.Portal.GetType().GetProperty("IsAcquired").GetValue(f.Portal), Is.True);
        f.Frame();
        Assert.That(f.Portal.GetType().GetProperty("IsAcquired").GetValue(f.Portal), Is.True);
        Assert.That(Field<Camera>(f.Portal, "portalCamera"), Is.SameAs(f.Camera));
    }

    [TestCase("{\"includeWorld\":true,\"viewportWidth\":1080,\"viewportHeight\":1600}", true)]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":3840,\"viewportHeight\":2160}", true)]
    [TestCase("{}", false)]
    [TestCase("{\"includeWorld\":false}", false)]
    public void SidecarParserAcceptsBoundedSceneAndLegacyCapture(string configuration, bool expectedWorld)
    {
        object command = ParseCapture(configuration);
        Assert.That(command.GetType().GetProperty("IncludeWorld", BindingFlags.Instance | BindingFlags.NonPublic)
            .GetValue(command), Is.EqualTo(expectedWorld));
    }

    [TestCase("{\"includeWorld\":\"true\",\"viewportWidth\":640,\"viewportHeight\":960}")]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":3841,\"viewportHeight\":960}")]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":640,\"viewportHeight\":2161}")]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":63,\"viewportHeight\":960}")]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":640.5,\"viewportHeight\":960}")]
    [TestCase("{\"includeWorld\":true,\"viewportWidth\":640}")]
    [TestCase("{\"includeWorld\":false,\"viewportWidth\":640,\"viewportHeight\":960}")]
    public void SidecarParserRejectsMalformedSceneCapture(string configuration)
    {
        TargetInvocationException error = Assert.Throws<TargetInvocationException>(() => ParseCapture(configuration));
        Assert.That(error.InnerException, Is.TypeOf<InvalidOperationException>());
    }

    private static object ParseCapture(string configuration)
    {
        Type jsonType = Type.GetType("Newtonsoft.Json.Linq.JObject, Newtonsoft.Json", true);
        string extra = configuration.Substring(1, configuration.Length - 2);
        string payload = "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactHigh\",\"targetFps\":30" +
            (extra.Length > 0 ? "," + extra : string.Empty) + "}";
        object json = jsonType.GetMethod("Parse", new[] { typeof(string) }).Invoke(null, new object[] { payload });
        return AvatarType("DesktopUnitySidecarBridge").GetMethod("ParsePortalCommand",
            BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new[] { json });
    }

    [Test]
    public void PropAddedAfterAcquireJoinsPortalIncludingInactiveNestedParts()
    {
        using var f = new Fixture();
        f.Acquire(1);
        var phone = new GameObject("Runtime phone") { layer = 0 };
        phone.transform.SetParent(f.Root.transform, false);
        phone.SetActive(false);
        GameObject screen = f.Part(phone.transform, "Nested screen", 12);
        GameObject keys = f.Part(screen.transform, "Nested keys", 17);

        f.Frame();

        int captureLayer = f.CaptureLayer;
        Assert.That(phone.layer, Is.EqualTo(captureLayer));
        Assert.That(screen.layer, Is.EqualTo(captureLayer));
        Assert.That(keys.layer, Is.EqualTo(captureLayer));
        Assert.That(f.Camera.cullingMask & (1 << captureLayer), Is.Zero,
            "The source camera must not also show the captured prop.");
        Camera portalCamera = Field<Camera>(f.Portal, "portalCamera");
        Assert.That(portalCamera.cullingMask, Is.EqualTo(1 << captureLayer));
        phone.SetActive(true);
        f.Frame();
        Assert.That(screen.layer, Is.EqualTo(captureLayer));

        f.Release(1);
        Assert.That(phone.layer, Is.EqualTo(0));
        Assert.That(screen.layer, Is.EqualTo(12));
        Assert.That(keys.layer, Is.EqualTo(17));
    }

    [Test]
    public void RepeatedFramesDoNotReplaceAuthoredLayersWithTheCaptureLayer()
    {
        using var f = new Fixture();
        f.Acquire(1);
        GameObject prop = f.Part(f.Root.transform, "Later accessory", 5);
        f.Frame();
        // A repeated synchronization owns this layer while capturing, but
        // must not overwrite the value first recorded for release.
        prop.layer = 7;
        for (int frame = 0; frame < 5; frame++) f.Frame();
        Assert.That(prop.layer, Is.EqualTo(f.CaptureLayer));

        f.Release(1);

        Assert.That(f.Root.layer, Is.EqualTo(8));
        Assert.That(f.Body.layer, Is.EqualTo(9));
        Assert.That(prop.layer, Is.EqualTo(5));
        Assert.That(f.Camera.cullingMask, Is.EqualTo(f.AuthoredCameraMask));
    }

    [Test]
    public void ReplacingAvatarRestoresOldPropsAndCapturesNewHierarchy()
    {
        using var f = new Fixture();
        f.Acquire(1);
        GameObject oldProp = f.Part(f.Root.transform, "Old phone", 6);
        f.Frame();
        var replacement = new GameObject("Replacement avatar") { layer = 10 };
        try
        {
            GameObject newBody = f.Part(replacement.transform, "New body", 11);
            Set(f.Receiver, "avatarRoot", replacement.transform);
            f.Frame();
            Assert.That(f.Root.layer, Is.EqualTo(8));
            Assert.That(f.Body.layer, Is.EqualTo(9));
            Assert.That(oldProp.layer, Is.EqualTo(6));
            Assert.That(replacement.layer, Is.EqualTo(f.CaptureLayer));
            Assert.That(newBody.layer, Is.EqualTo(f.CaptureLayer));

            GameObject newProp = f.Part(replacement.transform, "New phone", 14);
            f.Frame();
            Assert.That(newProp.layer, Is.EqualTo(f.CaptureLayer));
            f.Release(1);
            Assert.That(replacement.layer, Is.EqualTo(10));
            Assert.That(newBody.layer, Is.EqualTo(11));
            Assert.That(newProp.layer, Is.EqualTo(14));
        }
        finally
        {
            f.Release(0);
            Set(f.Receiver, "avatarRoot", f.Root.transform);
            Object.DestroyImmediate(replacement);
        }
    }

    [Test]
    public void DestroyedDynamicPropDoesNotBreakReleaseOrTheNextLease()
    {
        using var f = new Fixture();
        f.Acquire(1);
        GameObject prop = f.Part(f.Root.transform, "Disposable phone", 3);
        f.Frame();
        Object.DestroyImmediate(prop);
        f.Frame();
        Assert.DoesNotThrow(() => f.Release(1));
        Assert.That(f.Root.layer, Is.EqualTo(8));
        Assert.That(f.Body.layer, Is.EqualTo(9));

        f.Acquire(2);
        GameObject nextProp = f.Part(f.Root.transform, "Next phone", 4);
        f.Frame();
        Assert.That(nextProp.layer, Is.EqualTo(f.CaptureLayer));
        f.Release(2);
        Assert.That(nextProp.layer, Is.EqualTo(4));
        Assert.That(f.Camera.cullingMask, Is.EqualTo(f.AuthoredCameraMask));
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly GameObject Body;
        public readonly Component Receiver;
        public readonly Component Portal;
        public readonly Camera Camera;
        public readonly int AuthoredCameraMask = ~(1 << 25);
        public int CaptureLayer => Field<int>(Portal, "portalLayer");

        public Fixture()
        {
            if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
                Assert.Ignore("Acquiring the real portal requires a graphics device.");
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = new GameObject("Portal avatar") { layer = 8 };
            Body = Part(Root.transform, "Body", 9);
            Body.transform.localPosition = Vector3.up;
            Receiver = Root.AddComponent(AvatarType("UnityAvatarCommandReceiver"));
            Set(Receiver, "avatarRoot", Root.transform);
            var cameraHost = new GameObject("Main Camera") { tag = "MainCamera" };
            Camera = cameraHost.AddComponent<Camera>();
            Camera.cullingMask = AuthoredCameraMask;
            Camera.transform.position = new Vector3(0f, 1f, -5f);
            Portal = new GameObject("Portal layer regression")
                .AddComponent(AvatarType("CompanionPortalCaptureController"));
        }

        public GameObject Part(Transform parent, string name, int layer)
        {
            GameObject part = GameObject.CreatePrimitive(PrimitiveType.Cube);
            part.name = name;
            part.layer = layer;
            part.transform.SetParent(parent, false);
            return part;
        }

        public void Acquire(int generation) => Call(Portal, "Acquire", generation, "compactLow", 24);
        public void Frame() => Call(Portal, "LateUpdate");
        public void Release(int generation) => Call(Portal, "Release", generation);

        public void Dispose()
        {
            Release(0);
            Object.DestroyImmediate(Portal.gameObject);
            Object.DestroyImmediate(Camera.gameObject);
            Object.DestroyImmediate(Root);
        }
    }
}
