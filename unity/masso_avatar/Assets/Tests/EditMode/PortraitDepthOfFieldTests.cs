using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.Rendering;

public sealed class PortraitDepthOfFieldTests
{
    private const string TypeName =
        "Maaso.Avatar.PortraitDepthOfField, Assembly-CSharp";

    [Test]
    public void BackgroundStartsBehindTheWholeAvatarInsteadOfItsFace()
    {
        WithCamera((camera, _) =>
        {
            var body = new Bounds(new Vector3(0f, 1f, 4f), new Vector3(1f, 2f, 1f));
            float start = Static<float>("CalculateBackgroundStartDistance", camera, body, 0.35f);
            Assert.That(start, Is.EqualTo(4.85f).Within(0.001f));
            Assert.That(Static<float>("CalculateBlurWeight", 4.5f, start, 2f), Is.Zero);
            Assert.That(Static<float>("CalculateBlurWeight", 7f, start, 2f), Is.EqualTo(1f));
        });
    }

    [Test]
    public void FocusDepthUsesTheCameraDirectionAfterTranslationAndRotation()
    {
        WithCamera((camera, _) =>
        {
            camera.transform.SetPositionAndRotation(new Vector3(10f, 0f, 3f),
                Quaternion.Euler(0f, 90f, 0f));
            var body = new Bounds(new Vector3(14f, 0f, 3f), Vector3.one);
            Assert.That(Static<float>("CalculateBackgroundStartDistance", camera, body, 0.35f),
                Is.EqualTo(4.85f).Within(0.001f));
        });
    }

    [Test]
    public void BlurLeavesForegroundSharpAndIncreasesGraduallyInTheBackground()
    {
        float previous = 0f;
        foreach (float depth in new[] { 0.1f, 1f, 4f, 4.5f, 5f, 5.5f, 6f, 20f })
        {
            float weight = Static<float>("CalculateBlurWeight", depth, 4f, 2f);
            Assert.That(weight, Is.InRange(0f, 1f));
            Assert.That(weight, Is.GreaterThanOrEqualTo(previous));
            if (depth <= 4f) Assert.That(weight, Is.Zero);
            if (depth == 5f) Assert.That(weight, Is.GreaterThan(0f).And.LessThan(1f));
            if (depth >= 6f) Assert.That(weight, Is.EqualTo(1f));
            previous = weight;
        }
    }

    [Test]
    public void FocusTracksTheCurrentAvatarAndClearsWhenItDisappears()
    {
        WithCamera((camera, effect) =>
        {
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            try
            {
                body.transform.position = new Vector3(0f, 0f, 4f);
                Set(effect, "FocusTarget", body.transform);
                Assert.That(Invoke<bool>(effect, "UpdateFocus"), Is.True);
                Assert.That(Get<bool>(effect, "HasFocus"), Is.True);
                Assert.That(Get<float>(effect, "FocusDistance"), Is.EqualTo(4f).Within(0.01f));
                Assert.That(Get<float>(effect, "BackgroundStartDistance"), Is.GreaterThan(4.5f));
                body.transform.position = new Vector3(0f, 0f, 6f);
                Assert.That(Invoke<bool>(effect, "UpdateFocus"), Is.True);
                Assert.That(Get<float>(effect, "FocusDistance"), Is.EqualTo(6f).Within(0.01f));
                Set(effect, "FocusTarget", null);
                Assert.That(Invoke<bool>(effect, "UpdateFocus"), Is.False);
                Assert.That(Get<bool>(effect, "HasFocus"), Is.False);
                Assert.That(Get<bool>(effect, "CanRender"), Is.False);
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(body);
            }
        });
    }

    [Test]
    public void TransparentAvatarCapturesAndWorldOverviewDoNotApplyPortraitBlur()
    {
        WithCamera((camera, effect) =>
        {
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            try
            {
                body.transform.position = Vector3.forward * 4f;
                Set(effect, "FocusTarget", body.transform);
                Assert.That(Invoke<bool>(effect, "UpdateFocus"), Is.True);
                Assert.That(Get<bool>(effect, "CanRender"), Is.True);
                camera.backgroundColor = Color.clear;
                Assert.That(Get<bool>(effect, "CanRender"), Is.False,
                    "Transparent companion cutouts must preserve their existing render path.");
                camera.backgroundColor = Color.white;
                Type framingType = Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp");
                Assert.That(framingType, Is.Not.Null);
                var framing = (Behaviour)camera.gameObject.AddComponent(framingType);
                framing.enabled = false;
                Invoke<bool>(effect, "UpdateFocus");
                Assert.That(Get<bool>(effect, "CanRender"), Is.False,
                    "The world camera owns overview framing while home framing is disabled.");
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(body);
            }
        });
    }

    [Test]
    public void ShaderShipsAsALocalResource()
    {
        Shader shader = Resources.Load<Shader>("MaasoPortraitDepthOfField");
        Assert.That(shader, Is.Not.Null);
        Assert.That(shader.name, Is.EqualTo("Hidden/Maaso/PortraitDepthOfField"));
    }

    [TestCase(1)]
    [TestCase(4)]
    public void RenderedPortraitKeepsTheAvatarSharpAndSoftensDistantDetail(int samples)
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
        {
            Assert.Ignore("Image verification needs a graphics device; run Unity without -nographics.");
        }
        Shader flatShader = Shader.Find("Standard");
        Shader transparentShader = Shader.Find("Unlit/Transparent");
        Shader portraitShader = Resources.Load<Shader>("MaasoPortraitDepthOfField");
        Assert.That(flatShader, Is.Not.Null);
        Assert.That(transparentShader, Is.Not.Null);
        Assert.That(portraitShader, Is.Not.Null);
        Assert.That(portraitShader.isSupported, Is.True);
        WithCamera((camera, effect) =>
        {
            var stage = new GameObject("PortraitImageFixture");
            var red = new Material(flatShader) { color = Color.red };
            var dark = new Material(flatShader) { color = new Color(0.08f, 0.15f, 0.2f) };
            var bright = new Material(flatShader) { color = new Color(0.8f, 0.9f, 0.7f) };
            var hairTexture = new Texture2D(16, 16, TextureFormat.RGBA32, false)
            {
                filterMode = FilterMode.Point,
                wrapMode = TextureWrapMode.Clamp,
            };
            for (int y = 0; y < 16; y++)
                for (int x = 0; x < 16; x++)
                    hairTexture.SetPixel(x, y, new Color(0.8f, 0.05f, 0.9f, x < 8 ? 1f : 0f));
            hairTexture.Apply();
            var hair = new Material(transparentShader) { mainTexture = hairTexture };
            var invisible = new Material(Shader.Find("Sprites/Default")) { color = Color.clear };
            foreach (Material material in new[] { red, dark, bright })
            {
                material.SetColor("_EmissionColor", material.color);
                material.EnableKeyword("_EMISSION");
            }
            Texture2D original = null;
            Texture2D portrait = null;
            try
            {
                camera.cullingMask = 1 << 30;
                camera.fieldOfView = 40f;
                camera.aspect = 1f;
                var avatar = new GameObject("Avatar");
                avatar.transform.SetParent(stage.transform, false);
                var body = GameObject.CreatePrimitive(PrimitiveType.Cube);
                body.transform.SetParent(avatar.transform, false);
                body.transform.position = Vector3.forward * 4f;
                body.transform.localScale = new Vector3(0.8f, 1.6f, 0.5f);
                body.layer = 30;
                body.GetComponent<Renderer>().sharedMaterial = red;
                var hairCard = GameObject.CreatePrimitive(PrimitiveType.Quad);
                hairCard.transform.SetParent(avatar.transform, false);
                hairCard.transform.position = new Vector3(-0.7f, 0.65f, 3.6f);
                hairCard.transform.localScale = new Vector3(0.7f, 0.9f, 1f);
                hairCard.layer = 30;
                hairCard.GetComponent<Renderer>().sharedMaterial = hair;
                var invisibleCard = GameObject.CreatePrimitive(PrimitiveType.Quad);
                invisibleCard.transform.SetParent(avatar.transform, false);
                invisibleCard.transform.position = new Vector3(-0.85f, -0.7f, 3.6f);
                invisibleCard.transform.localScale = new Vector3(0.65f, 0.6f, 1f);
                invisibleCard.layer = 30;
                invisibleCard.GetComponent<Renderer>().sharedMaterial = invisible;
                for (int index = 0; index < 40; index++)
                {
                    var stripe = GameObject.CreatePrimitive(PrimitiveType.Cube);
                    stripe.transform.SetParent(stage.transform, false);
                    stripe.transform.position = new Vector3(-3.9f + index * 0.2f, 0f, 8f);
                    stripe.transform.localScale = new Vector3(0.2f, 8f, 0.1f);
                    stripe.layer = 30;
                    stripe.GetComponent<Renderer>().sharedMaterial = index % 2 == 0 ? dark : bright;
                }
                Set(effect, "FocusTarget", avatar.transform);
                ((Behaviour)effect).enabled = false;
                original = Capture(camera, samples);
                ((Behaviour)effect).enabled = true;
                Assert.That(Invoke<bool>(effect, "UpdateFocus"), Is.True);
                portrait = Capture(camera, samples);
                System.IO.File.WriteAllBytes(
                    System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"maaso-portrait-fixture-msaa{samples}-original.png"),
                    original.EncodeToPNG());
                System.IO.File.WriteAllBytes(
                    System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"maaso-portrait-fixture-msaa{samples}-blurred.png"),
                    portrait.EncodeToPNG());
                Color before = original.GetPixel(128, 128);
                Color after = portrait.GetPixel(128, 128);
                Assert.That(Mathf.Abs(before.r - after.r) + Mathf.Abs(before.g - after.g) +
                    Mathf.Abs(before.b - after.b), Is.LessThan(0.03f),
                    "Depth compositing must keep the foreground avatar color intact.");
                Assert.That(after.r, Is.GreaterThan(0.7f));
                Assert.That(DetailEnergy(portrait), Is.LessThan(DetailEnergy(original) * 0.9f),
                    "Distant stripes must lose visible high-frequency detail.");
                Assert.That(after.a, Is.EqualTo(before.a).Within(0.01f));
                Vector3 hairPixel = camera.WorldToViewportPoint(new Vector3(-0.9f, 0.85f, 3.6f));
                Color hairBefore = original.GetPixelBilinear(hairPixel.x, hairPixel.y);
                Color hairAfter = portrait.GetPixelBilinear(hairPixel.x, hairPixel.y);
                Assert.That(hairBefore.r, Is.GreaterThan(hairBefore.g + 0.3f));
                Assert.That(Mathf.Abs(hairBefore.r - hairAfter.r) +
                    Mathf.Abs(hairBefore.g - hairAfter.g) +
                    Mathf.Abs(hairBefore.b - hairAfter.b), Is.LessThan(0.06f),
                    "Offset transparent hair must stay sharp even without a depth pass; a flipped mask fails here.");
                Vector3 hiddenLeft = camera.WorldToViewportPoint(new Vector3(-1.1f, -0.7f, 3.6f));
                Vector3 hiddenRight = camera.WorldToViewportPoint(new Vector3(-0.6f, -0.7f, 3.6f));
                float hiddenOriginal = 0f;
                float hiddenPortrait = 0f;
                int hiddenY = Mathf.RoundToInt(hiddenLeft.y * 255f);
                for (int x = Mathf.CeilToInt(hiddenLeft.x * 255f);
                     x < Mathf.FloorToInt(hiddenRight.x * 255f); x++)
                {
                    hiddenOriginal += Mathf.Abs(original.GetPixel(x + 1, hiddenY).grayscale -
                        original.GetPixel(x, hiddenY).grayscale);
                    hiddenPortrait += Mathf.Abs(portrait.GetPixel(x + 1, hiddenY).grayscale -
                        portrait.GetPixel(x, hiddenY).grayscale);
                }
                Assert.That(hiddenOriginal, Is.GreaterThan(0.05f));
                Assert.That(hiddenPortrait, Is.LessThan(hiddenOriginal * 0.9f),
                    "A fully transparent material must not leave an unblurred rectangle in the room.");
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(stage);
                UnityEngine.Object.DestroyImmediate(red);
                UnityEngine.Object.DestroyImmediate(dark);
                UnityEngine.Object.DestroyImmediate(bright);
                UnityEngine.Object.DestroyImmediate(hair);
                UnityEngine.Object.DestroyImmediate(invisible);
                UnityEngine.Object.DestroyImmediate(hairTexture);
                UnityEngine.Object.DestroyImmediate(original);
                UnityEngine.Object.DestroyImmediate(portrait);
            }
        });
    }

    private static Texture2D Capture(Camera camera, int samples)
    {
        var target = new RenderTexture(256, 256, 24, RenderTextureFormat.ARGB32)
        {
            antiAliasing = samples,
        };
        RenderTexture previous = RenderTexture.active;
        RenderTexture previousTarget = camera.targetTexture;
        try
        {
            target.Create();
            camera.targetTexture = target;
            camera.Render();
            RenderTexture.active = target;
            var pixels = new Texture2D(256, 256, TextureFormat.RGBA32, false);
            pixels.ReadPixels(new Rect(0, 0, 256, 256), 0, 0);
            pixels.Apply();
            return pixels;
        }
        finally
        {
            camera.targetTexture = previousTarget;
            RenderTexture.active = previous;
            target.Release();
            UnityEngine.Object.DestroyImmediate(target);
        }
    }

    private static float DetailEnergy(Texture2D image)
    {
        float energy = 0f;
        for (int x = 190; x < 240; x++)
            energy += Mathf.Abs(image.GetPixel(x + 1, 128).grayscale - image.GetPixel(x, 128).grayscale);
        return energy;
    }

    private static void WithCamera(Action<Camera, Component> action)
    {
        var root = new GameObject("PortraitCameraFixture");
        try
        {
            Camera camera = root.AddComponent<Camera>();
            camera.enabled = false;
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = Color.white;
            camera.nearClipPlane = 0.1f;
            camera.farClipPlane = 30f;
            action(camera, root.AddComponent(EffectType()));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    private static Type EffectType()
    {
        Type type = Type.GetType(TypeName);
        Assert.That(type, Is.Not.Null, TypeName);
        return type;
    }

    private static T Static<T>(string name, params object[] args) =>
        (T)EffectType().GetMethod(name, BindingFlags.Public | BindingFlags.Static).Invoke(null, args);

    private static T Invoke<T>(Component target, string name) =>
        (T)target.GetType().GetMethod(name).Invoke(target, null);

    private static T Get<T>(Component target, string name) =>
        (T)target.GetType().GetProperty(name).GetValue(target);

    private static void Set(Component target, string name, object value) =>
        target.GetType().GetProperty(name).SetValue(target, value);
}
