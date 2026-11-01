using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class DefaultAvatarSmileTests
{
    private static readonly string[][] SmileShapes =
    {
        new[] { "Smile_L", "Smile_R" },
        new[] { "Face_Blendshape.Fcl_MTH_Fun" },
        new[] { "Fcl_MTH_Fun" },
    };
    private static readonly ExpressionKey[] Vowels =
        { ExpressionKey.Aa, ExpressionKey.Ih, ExpressionKey.Ou, ExpressionKey.Ee, ExpressionKey.Oh };

    private static object Call(object target, string name, params object[] args) =>
        target.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length)
            .Invoke(target, args);
    private static void Command(Component receiver, string method, string payload) =>
        Call(receiver, "OnFlutterCommand", "{\"method\":\"" + method + "\",\"json\":\"" +
            payload.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}");

    [Test]
    public void DefaultVrmIsNeutralWithoutForcedSmileBlinkOrVowels()
    {
        using var f = new Fixture();
        f.Process();
        f.AssertSmile();
        f.AssertSilent();
        Assert.That(f.Expression.GetWeight(ExpressionKey.Happy), Is.Zero);
        Assert.That(f.Expression.ActualWeights[ExpressionKey.Happy], Is.Zero);
        Assert.That(f.Expression.BlinkOverrideRate, Is.Zero);
        Assert.That(f.Expression.MouthOverrideRate, Is.Zero);
        foreach (ExpressionKey blink in new[] { ExpressionKey.Blink, ExpressionKey.BlinkLeft, ExpressionKey.BlinkRight })
        {
            Assert.That(f.Expression.GetWeight(blink), Is.Zero, blink.ToString());
            Assert.That(f.Expression.ActualWeights[blink], Is.Zero, blink.ToString());
        }
        f.AssertExpressionMorphsSilent(f.Vrm.Vrm.Expression.Happy);
        f.AssertExpressionMorphsSilent(f.Vrm.Vrm.Expression.Blink);
        f.AssertExpressionMorphsSilent(f.Vrm.Vrm.Expression.BlinkLeft);
        f.AssertExpressionMorphsSilent(f.Vrm.Vrm.Expression.BlinkRight);
        for (int index = 0; index < f.Face.sharedMesh.blendShapeCount; index++)
            if (!f.SmileIndices.Contains(index) &&
                !f.Face.sharedMesh.GetBlendShapeName(index).StartsWith("Maaso.Joy.Elbow.", StringComparison.Ordinal))
                Assert.That(f.Face.GetBlendShapeWeight(index), Is.Zero,
                    f.Face.sharedMesh.GetBlendShapeName(index));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void NonVrmSmileAliasesRemainNeutralUntilRequestedAndKeepSpeechOwnership(bool singleSmile)
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var root = new GameObject("NonVrmSmileAvatar");
        var mesh = new Mesh();
        try
        {
            mesh.vertices = new[] { Vector3.zero, Vector3.up, Vector3.right };
            mesh.triangles = new[] { 0, 1, 2 };
            string[] smiles = singleSmile ? new[] { "Smile2" } : new[] { "Smile_L", "Smile_R" };
            foreach (string name in smiles.Concat(new[] { "A", "Blink" }))
                mesh.AddBlendShapeFrame(name, 100f,
                    new[] { Vector3.up * 0.01f, Vector3.zero, Vector3.zero }, null, null);
            SkinnedMeshRenderer face = root.AddComponent<SkinnedMeshRenderer>();
            face.sharedMesh = mesh;
            Component receiver = root.AddComponent(Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
            Call(receiver, "BindAvatarRoot", root.transform);
            foreach (string name in smiles)
                Assert.That(face.GetBlendShapeWeight(mesh.GetBlendShapeIndex(name)), Is.Zero.Within(0.01f));
            Command(receiver, "setExpression", "{\"happy\":0.8,\"eyeOpen\":1}");
            Call(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
            foreach (string name in smiles)
                Assert.That(face.GetBlendShapeWeight(mesh.GetBlendShapeIndex(name)), Is.GreaterThan(50f), name);
            Command(receiver, "setMouthOpen", "{\"value\":0.8}");
            Assert.That(face.GetBlendShapeWeight(mesh.GetBlendShapeIndex("A")), Is.EqualTo(80f).Within(0.01f));
            Command(receiver, "stopLipSync", "{}");
            Assert.That(face.GetBlendShapeWeight(mesh.GetBlendShapeIndex("A")), Is.Zero);
        }
        finally
        {
            Object.DestroyImmediate(root);
            Object.DestroyImmediate(mesh);
        }
    }

    [Test]
    public void VrmExpressionOwnedMouthShapeIsNotWrittenByTheDefaultSmile()
    {
        using var f = new Fixture(bindSmileToExpression: true);
        ExpressionKey key = ExpressionKey.CreateCustom("owned_resting_smile");
        f.Expression.SetWeight(key, 0.7f);
        f.Process();
        Call(f.Receiver, "ApplyExpression");
        foreach (int index in f.SmileIndices)
            Assert.That(f.Face.GetBlendShapeWeight(index), Is.EqualTo(70f).Within(0.01f),
                "The custom expression owns each smile morph, including after receiver expression updates.");
        f.Expression.SetWeight(key, 0f);
        f.Process();
        Call(f.Receiver, "ApplyExpression");
        foreach (int index in f.SmileIndices)
            Assert.That(f.Face.GetBlendShapeWeight(index), Is.Zero);
    }

    [TestCase("neutral")]
    [TestCase("stopLipSync")]
    [TestCase("productionReset")]
    [TestCase("rebind")]
    [TestCase("disableEnable")]
    public void PresentationBoundariesReturnToNeutral(string boundary)
    {
        using var f = new Fixture();
        Command(f.Receiver, "setMouthOpen", "{\"value\":0.8}");
        Command(f.Receiver, "stopLipSync", "{}");
        switch (boundary)
        {
            case "neutral":
                Command(f.Receiver, "setExpression", "{\"happy\":0,\"mouthSmile\":0,\"eyeOpen\":1}");
                Call(f.Receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
                break;
            case "stopLipSync":
                f.StartTimeline("aa");
                Command(f.Receiver, "stopLipSync", "{}");
                break;
            case "productionReset":
                Assert.That(Call(f.Receiver, "ResetAvatarArbiterState"), Is.True);
                break;
            case "rebind":
                Call(f.Receiver, "BindAvatarRoot", f.Vrm.transform);
                break;
            case "disableEnable":
                ((Behaviour)f.Receiver).enabled = false;
                ((Behaviour)f.Receiver).enabled = true;
                Call(f.Receiver, "LateUpdate");
                break;
        }
        f.Process();
        f.AssertSmile();
        f.AssertSilent();
    }

    [TestCase("aa", 0)]
    [TestCase("ih", 1)]
    [TestCase("ou", 2)]
    [TestCase("ee", 3)]
    [TestCase("oh", 4)]
    public void NeutralFaceDoesNotAttenuateAnyVowelAndSilentTimelineFramesStaySilent(string viseme, int activeIndex)
    {
        using var f = new Fixture();
        f.StartTimeline(viseme);
        f.Process();
        f.AssertSmile();
        for (int index = 0; index < Vowels.Length; index++)
        {
            float input = f.Expression.GetWeight(Vowels[index]);
            float actual = f.Expression.ActualWeights[Vowels[index]];
            if (index == activeIndex) Assert.That(input, Is.GreaterThan(0.35f));
            else Assert.That(input, Is.Zero);
            Assert.That(actual, Is.EqualTo(input).Within(0.0001f), Vowels[index].ToString());
        }
        Assert.That(f.Expression.MouthOverrideRate, Is.Zero);
        Call(f.Receiver, "ApplyLipSyncFrame", 1f);
        f.Process();
        f.AssertSilent();
        f.AssertSmile();
        Command(f.Receiver, "stopLipSync", "{}");
        f.Process();
        f.AssertSilent();
        f.AssertSmile();
    }

    [Test]
    public void DefaultVrmRendersNeutralAndExplicitGentleSmileMouthCloseups()
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("The smile visual regression requires a graphics device.");
        using var f = new Fixture();
        Camera camera = Camera.main;
        Animator animator = f.Vrm.GetComponentInChildren<Animator>();
        animator.Rebind();
        animator.Update(0f);
        f.Process();
        // Render the actual neutral morph as the before reference. This does
        // not edit the image or mutate the imported VRM asset.
        foreach (int index in f.SmileIndices)
            f.Face.SetBlendShapeWeight(index, 0f);
        f.Process();
        Bounds mouth = f.MouthBounds();
        camera.aspect = 1f;
        camera.fieldOfView = 35f;
        camera.nearClipPlane = 0.005f;
        float span = Mathf.Max(mouth.size.x * 1.3f, mouth.size.y * 2f);
        float distance = span * 0.5f / Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * 0.5f) + mouth.extents.z;
        camera.transform.position = mouth.center - camera.transform.forward * distance;
        byte[] neutralImage = Capture(camera, "neutral", f.Face);
        Vector3[] neutral = f.BakedVertices();
        Command(f.Receiver, "setExpression", "{\"happy\":0.35,\"eyeOpen\":1}");
        Call(f.Receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
        f.Process();
        byte[] smilingImage = Capture(camera, "smile", f.Face);
        foreach (int index in f.SmileIndices)
            Assert.That(f.Face.GetBlendShapeWeight(index), Is.Zero,
                "The duplicate independent smile aliases stay zero; VRM Happy owns the original lip shape.");
        Assert.That(f.Expression.GetWeight(ExpressionKey.Happy), Is.InRange(.2f, .3f));
        Assert.That(neutralImage.SequenceEqual(smilingImage), Is.False,
            "The two rendered images must contain the actual visible morph change.");
        Vector3[] smiling = f.BakedVertices();
        Assert.That(neutral.Zip(smiling, Vector3.Distance).Max(), Is.GreaterThan(0.0001f),
            "The smile must reach the rendered mesh after the real VRM runtime processes it.");
    }

    private static byte[] Capture(Camera camera, string label, SkinnedMeshRenderer face)
    {
        RenderTexture previousTarget = camera.targetTexture;
        RenderTexture previousActive = RenderTexture.active;
        var target = new RenderTexture(720, 720, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(720, 720, TextureFormat.RGBA32, false);
        var bakedMesh = new Mesh();
        var bakedFace = new GameObject("ProcessedSmileRenderEvidence");
        bool faceWasEnabled = face.enabled;
        try
        {
            // EditMode does not refresh GPU skinning between two Camera.Render
            // calls in one frame. Render the real processed pose baked by Unity,
            // using the avatar's own materials, so both samples are current.
            face.BakeMesh(bakedMesh);
            bakedFace.transform.SetParent(face.transform, false);
            bakedFace.layer = face.gameObject.layer;
            bakedFace.AddComponent<MeshFilter>().sharedMesh = bakedMesh;
            bakedFace.AddComponent<MeshRenderer>().sharedMaterials = face.sharedMaterials;
            face.enabled = false;
            camera.targetTexture = target;
            camera.Render();
            RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, 720, 720), 0, 0);
            image.Apply();
            byte[] png = image.EncodeToPNG();
            File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "maaso-default-mouth-" + label + ".png"), png);
            return png;
        }
        finally
        {
            face.enabled = faceWasEnabled;
            Object.DestroyImmediate(bakedFace);
            Object.DestroyImmediate(bakedMesh);
            camera.targetTexture = previousTarget;
            RenderTexture.active = previousActive;
            Object.DestroyImmediate(target);
            Object.DestroyImmediate(image);
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Vrm10Instance Vrm;
        public readonly Component Receiver;
        public readonly SkinnedMeshRenderer Face;
        public readonly int[] SmileIndices;
        private readonly VRM10Object copiedDefinition;
        private readonly VRM10Expression ownedSmile;
        public Vrm10RuntimeExpression Expression => Vrm.Runtime.Expression;

        public Fixture(bool bindSmileToExpression = false)
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Vrm = Object.FindAnyObjectByType<Vrm10Instance>();
            Receiver = Object.FindAnyObjectByType(Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true)) as Component;
            SkinnedMeshRenderer[] renderers = Vrm.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            string[] smiles = SmileShapes.FirstOrDefault(group => renderers.Any(item =>
                item.sharedMesh != null && group.All(name => item.sharedMesh.GetBlendShapeIndex(name) >= 0)));
            Assert.That(smiles, Is.Not.Null, "The default avatar needs a complete mouth-only smile alias group.");
            Face = renderers.Single(item => item.sharedMesh != null &&
                smiles.All(name => item.sharedMesh.GetBlendShapeIndex(name) >= 0));
            SmileIndices = smiles.Select(name => Face.sharedMesh.GetBlendShapeIndex(name)).ToArray();
            Assert.That(SmileIndices.Distinct().Count(), Is.EqualTo(smiles.Length),
                "Left and right smile aliases must remain independently addressable.");
            if (bindSmileToExpression)
            {
                // Configure the incoming model before its runtime is created,
                // matching real model loading and avoiding hot Reload in EditMode.
                copiedDefinition = Object.Instantiate(Vrm.Vrm);
                ownedSmile = ScriptableObject.CreateInstance<VRM10Expression>();
                ownedSmile.name = "owned_resting_smile";
                string facePath = AnimationUtility.CalculateTransformPath(Face.transform, Vrm.transform);
                ownedSmile.MorphTargetBindings = SmileIndices
                    .Select(index => new MorphTargetBinding(facePath, index, 1f)).ToArray();
                copiedDefinition.Expression.AddClip(ExpressionPreset.custom, ownedSmile);
                Vrm.Vrm = copiedDefinition;
            }
            // UniVRM accesses renderer.materials during prefab initialization;
            // Unity logs its EditMode warning for each instantiated material slot.
            int materialAccessCount = Vrm.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialAccessCount; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Call(Receiver, "Awake");
            Call(Receiver, "ApplyExpression");
        }
        public void Process() => Vrm.Runtime.Process();
        public void AssertSmile()
        {
            foreach (int index in SmileIndices)
                Assert.That(Face.GetBlendShapeWeight(index), Is.Zero.Within(0.01f),
                    Face.sharedMesh.GetBlendShapeName(index));
        }
        public void AssertSilent()
        {
            foreach (ExpressionKey vowel in Vowels)
            {
                Assert.That(Expression.GetWeight(vowel), Is.Zero, vowel.ToString());
                Assert.That(Expression.ActualWeights[vowel], Is.Zero, vowel.ToString());
            }
            foreach (VRM10Expression vowel in new[]
                { Vrm.Vrm.Expression.Aa, Vrm.Vrm.Expression.Ih, Vrm.Vrm.Expression.Ou,
                    Vrm.Vrm.Expression.Ee, Vrm.Vrm.Expression.Oh })
                AssertExpressionMorphsSilent(vowel);
        }
        public void AssertExpressionMorphsSilent(VRM10Expression clip)
        {
            Assert.That(clip, Is.Not.Null);
            Assert.That(clip.MorphTargetBindings, Is.Not.Empty, clip.name);
            foreach (MorphTargetBinding binding in clip.MorphTargetBindings)
            {
                Transform target = string.IsNullOrEmpty(binding.RelativePath)
                    ? Vrm.transform : Vrm.transform.Find(binding.RelativePath);
                Assert.That(target, Is.Not.Null, binding.RelativePath);
                SkinnedMeshRenderer renderer = target.GetComponent<SkinnedMeshRenderer>();
                Assert.That(renderer, Is.Not.Null, binding.RelativePath);
                Assert.That(renderer.sharedMesh, Is.Not.Null, binding.RelativePath);
                Assert.That(binding.Index, Is.InRange(0, renderer.sharedMesh.blendShapeCount - 1), clip.name);
                Assert.That(renderer.GetBlendShapeWeight(binding.Index), Is.Zero,
                    clip.name + ": " + renderer.sharedMesh.GetBlendShapeName(binding.Index));
            }
        }
        public void StartTimeline(string viseme) => Command(Receiver, "startVisemeTimeline",
            "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"" + viseme + "\"}],\"frameRate\":30}");
        public Vector3[] BakedVertices()
        {
            var mesh = new Mesh();
            try { Face.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }
        public Bounds MouthBounds()
        {
            Vector3[] vertices = BakedVertices();
            var deltas = new Vector3[vertices.Length];
            Bounds bounds = default;
            bool initialized = false;
            foreach (int smileIndex in SmileIndices)
            {
                Face.sharedMesh.GetBlendShapeFrameVertices(smileIndex, 0, deltas, null, null);
                bool hasDelta = false;
                for (int index = 0; index < vertices.Length; index++)
                {
                    if (deltas[index].sqrMagnitude < 0.000000000001f) continue;
                    hasDelta = true;
                    Vector3 point = Face.transform.TransformPoint(vertices[index]);
                    if (!initialized) { bounds = new Bounds(point, Vector3.zero); initialized = true; }
                    else bounds.Encapsulate(point);
                }
                Assert.That(hasDelta, Is.True, Face.sharedMesh.GetBlendShapeName(smileIndex));
            }
            Assert.That(initialized, Is.True);
            return bounds;
        }
        public void Dispose()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            if (copiedDefinition != null) Object.DestroyImmediate(copiedDefinition);
            if (ownedSmile != null) Object.DestroyImmediate(ownedSmile);
        }
    }
}
