using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarJoyElbowCorrectivesTests
{
    private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private const string Profile = "Assets/Resources/MaasoAvatar/joy_elbow_correctives.json";
    private const string ReferenceProfile = "Assets/Tests/EditMode/Editor/AvatarJoyR80ElbowReference.json";
    private const string Golden = "Assets/Tests/EditMode/Editor/AvatarJoyElbowGeometryGolden.json";
    private static readonly Type Helper = Type.GetType("Maaso.Avatar.AvatarJoyElbowCorrectives, Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => Helper.GetMethod(method).Invoke(value, args);
    private static object Static(string method, params object[] args) => Helper.GetMethod(method).Invoke(null, args);

    [Test]
    public void ActualBindPreservesOriginalMeshExpressionsNormalsTangentsAndAllJoints()
    {
        using var f = new Fixture();
        Mesh source = f.Body.sharedMesh;
        Vector3[] points = source.vertices, normals = source.normals;
        Vector4[] tangents = source.tangents;
        string[] names = Enumerable.Range(0, source.blendShapeCount).Select(source.GetBlendShapeName).ToArray();
        for (int i = 0; i < names.Length; i++) f.Body.SetBlendShapeWeight(i, i % 13);
        float[] expressions = Enumerable.Range(0, names.Length).Select(f.Body.GetBlendShapeWeight).ToArray();
        var pose = f.Avatar.GetComponentsInChildren<Transform>(true).ToDictionary(t => t, t => (t.localPosition, t.localRotation, t.localScale));
        f.Bind();
        Assert.That(f.Body.sharedMesh, Is.Not.SameAs(source));
        Assert.That(source.blendShapeCount, Is.EqualTo(names.Length), "Never append frames to the imported shared asset.");
        Assert.That(f.Body.sharedMesh.blendShapeCount, Is.EqualTo(names.Length + 20));
        Assert.That(Enumerable.Range(0, names.Length).Select(f.Body.sharedMesh.GetBlendShapeName), Is.EqualTo(names));
        Assert.That(f.Body.sharedMesh.vertices, Is.EqualTo(points));
        Assert.That(f.Body.sharedMesh.normals, Is.EqualTo(normals));
        Assert.That(f.Body.sharedMesh.tangents, Is.EqualTo(tangents));
        Mesh clone = f.Body.sharedMesh;
        for (int frame = 0; frame < 100; frame++) Call(f.Component, "ApplyAfterVrm");
        Assert.That(f.Body.sharedMesh, Is.SameAs(clone), "Frames only change GPU shape weights.");
        Assert.That(Enumerable.Range(0, names.Length).Select(f.Body.GetBlendShapeWeight), Is.EqualTo(expressions));
        foreach (var pair in pose)
        {
            Assert.That(pair.Key.localPosition, Is.EqualTo(pair.Value.localPosition), pair.Key.name);
            Assert.That(pair.Key.localRotation, Is.EqualTo(pair.Value.localRotation), pair.Key.name);
            Assert.That(pair.Key.localScale, Is.EqualTo(pair.Value.localScale), pair.Key.name);
        }
        Call(f.Component, "Reset");
        Assert.That(f.Body.sharedMesh, Is.SameAs(source));
        Assert.That(source.vertices, Is.EqualTo(points));
    }

    [TestCase("L", 60)] [TestCase("L", 90)] [TestCase("L", 120)]
    [TestCase("R", 60)] [TestCase("R", 90)] [TestCase("R", 120)]
    [TestCase("L", 75)] [TestCase("L", 105)] [TestCase("R", 75)] [TestCase("R", 105)]
    [TestCase("L", 7.5f)] [TestCase("L", 22.5f)] [TestCase("L", 37.5f)] [TestCase("L", 52.5f)]
    [TestCase("L", 67.5f)] [TestCase("L", 82.5f)] [TestCase("L", 97.5f)] [TestCase("L", 112.5f)] [TestCase("L", 127.5f)]
    [TestCase("R", 7.5f)] [TestCase("R", 22.5f)] [TestCase("R", 37.5f)] [TestCase("R", 52.5f)]
    [TestCase("R", 67.5f)] [TestCase("R", 82.5f)] [TestCase("R", 97.5f)] [TestCase("R", 112.5f)] [TestCase("R", 127.5f)]
    public void ActualGpuBlendShapeSkinMatchesIndependentOriginalCorrectiveSmooth(string side, float degrees)
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        JObject sample = ((JArray)golden["samples"]).Cast<JObject>().Single(row => (string)row["side"] == side && (float)row["fkDegrees"] == degrees);
        var bones = f.Avatar.GetComponentsInChildren<Transform>(true).ToDictionary(t => t.name);
        foreach (var row in ((JObject)sample["bones"]).Properties().OrderBy(row => Depth(bones[row.Name])))
        {
            Matrix4x4 matrix = Matrix(row.Value);
            bones[row.Name].SetPositionAndRotation(matrix.GetColumn(3), Quaternion.LookRotation(matrix.GetColumn(2), matrix.GetColumn(1)));
        }
        f.Body.quality = SkinQuality.Bone4;
        var before = new Mesh();
        var reference = new Mesh();
        var after = new Mesh();
        Mesh original = f.Body.sharedMesh;
        Mesh frozenSkin = null;
        try
        {
            f.Body.BakeMesh(before);
            // Retain the ORIGINAL exact-source GPU gate against a frozen R80
            // test fixture. Naturalization does not silently widen its bounds.
            JObject oldProfile = JObject.Parse(File.ReadAllText(ReferenceProfile));
            frozenSkin = MountFrozenReference(f.Body, oldProfile);
            f.Body.BakeMesh(reference);
            CheckSurface(f.Body, before, reference, sample, oldProfile,
                "positions", "normals", degrees, originalSourceGate: true);
            f.Body.sharedMesh = original;
            Object.DestroyImmediate(frozenSkin); frozenSkin = null;
            int originalExpressions = original.blendShapeCount;
            f.Bind();
            Call(f.Component, "ApplyAfterVrm");
            f.Body.BakeMesh(after);
            JObject naturalProfile = JObject.Parse(File.ReadAllText(Profile));
            CheckSurface(f.Body, reference, after, sample, naturalProfile,
                "naturalPositions", "naturalNormals", degrees, originalSourceGate: false);
            int[] indices = sample["indices"].ToObject<int[]>();
            float[] expectedReference = sample["baselineR80Positions"].ToObject<float[]>();
            for (int point = 0; point < indices.Length; point++)
            {
                Vector3 expected = new(expectedReference[point * 3], expectedReference[point * 3 + 1], expectedReference[point * 3 + 2]);
                Assert.That(Vector3.Distance(f.Body.transform.TransformPoint(reference.vertices[indices[point]]), expected),
                    Is.LessThan(.00004f), "Offline naturalization must start from ACTUAL preceding GPU positions.");
                Assert.That(Vector3.Distance(reference.vertices[indices[point]], after.vertices[indices[point]]),
                    Is.LessThan(.00805f), "Actual GPU naturalization stays within its reviewed 8 mm local displacement envelope.");
            }
            var owned = new HashSet<int>(naturalProfile["arms"].SelectMany(arm => arm["indices"].Values<int>()));
            Vector3[] a = before.vertices, b = after.vertices;
            for (int vertex = 0; vertex < a.Length; vertex++)
                if (!owned.Contains(vertex)) Assert.That(Vector3.Distance(a[vertex], b[vertex]), Is.LessThan(.000001f), "Unrelated skin vertex " + vertex);
            for (int index = 0; index < originalExpressions; index++) Assert.That(f.Body.GetBlendShapeWeight(index), Is.Zero);
        }
        finally
        {
            if (frozenSkin != null) { f.Body.sharedMesh = original; Object.DestroyImmediate(frozenSkin); }
            Object.DestroyImmediate(before); Object.DestroyImmediate(reference); Object.DestroyImmediate(after);
        }
    }

    private static void CheckSurface(SkinnedMeshRenderer body, Mesh baseline, Mesh candidate, JObject sample,
        JObject profile, string positions, string normals, float degrees, bool originalSourceGate)
    {
        Vector3[] a = baseline.vertices, b = candidate.vertices;
        int[] indices = sample["indices"].ToObject<int[]>(); float[] target = sample[positions].ToObject<float[]>();
        var before = new List<float>(); var after = new List<float>();
        for (int point = 0; point < indices.Length; point++)
        {
            Vector3 expected = new(target[point * 3], target[point * 3 + 1], target[point * 3 + 2]);
            before.Add(Vector3.Distance(body.transform.TransformPoint(a[indices[point]]), expected));
            after.Add(Vector3.Distance(body.transform.TransformPoint(b[indices[point]]), expected));
        }
        bool knot = Mathf.Abs(degrees % 15f) < .001f;
        TestContext.WriteLine(positions + "/FK" + degrees + " mean m " + before.Average() + " -> " + after.Average() + "; max " + before.Max() + " -> " + after.Max());
        if (originalSourceGate)
        {
            Assert.That(before.Max(), Is.GreaterThan(.0001f));
            Assert.That(after.Average(), Is.LessThan(before.Average() * .1f), "Original R80 source gate remains unchanged.");
        }
        Assert.That(after.Max(), Is.LessThan(knot ? .00004f : .0012f), "No silent widening of exact/holdout surface accuracy.");
        float[] expectedNormals = sample[normals].ToObject<float[]>();
        var normalBefore = new List<float>(); var normalAfter = new List<float>(); var safeAfter = new List<float>();
        var fallback = new HashSet<int>(profile["normalFallbackIndices"].Values<int>());
        Vector3[] na = baseline.normals, nb = candidate.normals;
        for (int point = 0; point < indices.Length; point++)
        {
            Vector3 expected = new(expectedNormals[point * 3], expectedNormals[point * 3 + 1], expectedNormals[point * 3 + 2]);
            normalBefore.Add(Vector3.Angle(body.transform.TransformDirection(na[indices[point]]), expected));
            normalAfter.Add(Vector3.Angle(body.transform.TransformDirection(nb[indices[point]]), expected));
            if (fallback.Contains(indices[point]))
                Assert.That(Vector3.Angle(na[indices[point]], nb[indices[point]]), Is.LessThan(.05f),
                    originalSourceGate ? "R80 fallback retains imported baseline." : "Natural fallback retains exact preceding R80 shader normals.");
            else safeAfter.Add(normalAfter[normalAfter.Count - 1]);
            Assert.That(normalAfter[normalAfter.Count - 1] - normalBefore[normalBefore.Count - 1], Is.LessThan(1.1f), "No newly worse sampled shader-normal fold.");
        }
        if (knot)
        {
            Assert.That(safeAfter.Average(), Is.LessThan(.05f));
            Assert.That(safeAfter.Max(), Is.LessThan(.15f));
        }
        else if (originalSourceGate)
        {
            Assert.That(normalAfter.Average(), Is.LessThan(normalBefore.Average() * .7f));
            Assert.That(Percentile95(normalAfter), Is.LessThan(Percentile95(normalBefore) * .75f));
            Assert.That(normalAfter.Max(), Is.LessThan(normalBefore.Max() + .1f));
        }
    }

    private static Mesh MountFrozenReference(SkinnedMeshRenderer body, JObject data)
    {
        Mesh original = body.sharedMesh, clone = Object.Instantiate(original);
        var byName = body.bones.ToDictionary(bone => bone.name);
        int firstShape = clone.blendShapeCount;
        foreach (JObject arm in data["arms"])
        {
            int[] indices = arm["indices"].ToObject<int[]>();
            for (int knot = 0; knot < ((JArray)arm["samples"]).Count; knot++)
            {
                var positions = new Vector3[clone.vertexCount]; var normals = new Vector3[clone.vertexCount];
                float[] p = arm["samples"][knot]["deltaPositions"].ToObject<float[]>(), n = arm["samples"][knot]["deltaNormals"].ToObject<float[]>();
                for (int point = 0; point < indices.Length; point++)
                {
                    positions[indices[point]] = new Vector3(p[point * 3], p[point * 3 + 1], p[point * 3 + 2]);
                    normals[indices[point]] = new Vector3(n[point * 3], n[point * 3 + 1], n[point * 3 + 2]);
                }
                clone.AddBlendShapeFrame("Frozen.R80." + (string)arm["side"] + "." + knot, 100f, positions, normals, null);
            }
        }
        body.sharedMesh = clone;
        foreach (JObject arm in data["arms"])
        {
            string side = (string)arm["side"]; Transform upper = byName["DEF-upper_arm." + side], lower = byName["DEF-forearm." + side], hand = byName["DEF-hand." + side];
            float angle = Vector3.Angle(lower.position - upper.position, hand.position - lower.position);
            Matrix4x4 u = original.bindposes[Array.IndexOf(body.bones, upper)].inverse, f = original.bindposes[Array.IndexOf(body.bones, lower)].inverse;
            Quaternion offset = Quaternion.Inverse(Quaternion.LookRotation(u.GetColumn(2), u.GetColumn(1))) * Quaternion.LookRotation(f.GetColumn(2), f.GetColumn(1));
            float influence = (float)Static("RollInfluence", upper.rotation, lower.rotation, offset, hand.position - lower.position);
            object[] args = { arm["samples"].Select(row => (float)row["flexDegrees"]).ToArray(), angle, 0, 0, 0f };
            Helper.GetMethod("SelectKnots").Invoke(null, args);
            int a = (int)args[2], b = (int)args[3]; float mix = (float)args[4];
            for (int knot = 0; knot < ((JArray)arm["samples"]).Count; knot++)
                body.SetBlendShapeWeight(firstShape++, (knot == a ? 100f * (1 - mix) : knot == b ? 100f * mix : 0f) * influence);
        }
        return clone;
    }

    [Test]
    public void ChangedMeshOrModelFailsClosedAndResetRespectsLaterMeshOwner()
    {
        using var f = new Fixture();
        Mesh original = f.Body.sharedMesh;
        Mesh altered = Object.Instantiate(original);
        try
        {
            Vector3[] points = altered.vertices; points[0] += Vector3.up * .001f; altered.vertices = points;
            f.Body.sharedMesh = altered;
            Assert.That(Call(f.Component, "Bind", f.Avatar.transform), Is.False);
            Assert.That(f.Body.sharedMesh, Is.SameAs(altered));
            f.Body.sharedMesh = original;
            f.Bind();
            f.Body.sharedMesh = altered;
            Call(f.Component, "Reset");
            Assert.That(f.Body.sharedMesh, Is.SameAs(altered), "A later renderer owner must not be replaced on release.");
        }
        finally { f.Body.sharedMesh = original; Object.DestroyImmediate(altered); }
        var other = new GameObject("unreviewed avatar");
        try { Assert.That(Call(f.Component, "Bind", other.transform), Is.False); }
        finally { Object.DestroyImmediate(other); }
    }

    [Test]
    public void ChangedSplitNormalsFailClosedEvenWhenPositionsAndWeightsStillMatch()
    {
        using var f = new Fixture();
        Mesh original = f.Body.sharedMesh;
        Mesh altered = Object.Instantiate(original);
        try
        {
            Vector3[] normals = altered.normals;
            normals[0] = Quaternion.Euler(13f, 17f, 0f) * normals[0];
            altered.normals = normals;
            Assert.That(Static("ComputeMeshFingerprint", altered, f.Body.bones),
                Is.EqualTo(Static("ComputeMeshFingerprint", original, f.Body.bones)), "Position/weight guard alone cannot detect this change.");
            f.Body.sharedMesh = altered;
            Assert.That(Call(f.Component, "Bind", f.Avatar.transform), Is.False);
            Assert.That(Helper.GetProperty("LastFailure").GetValue(f.Component), Is.EqualTo("Body split normals changed"));
            Assert.That(f.Body.sharedMesh, Is.SameAs(altered));
        }
        finally { f.Body.sharedMesh = original; Object.DestroyImmediate(altered); }
    }

    [TestCase("source")] [TestCase("naturalPolicy")] [TestCase("previousNaturalPolicy")] [TestCase("reference")] [TestCase("indices")] [TestCase("angle")] [TestCase("position")] [TestCase("normal")]
    public void MalformedOrUnreviewedProfileIsRejected(string mutation)
    {
        JObject profile = JObject.Parse(File.ReadAllText(Profile));
        if (mutation == "source") profile["sourceSha256"] = new string('0', 64);
        if (mutation == "naturalPolicy") profile["naturalizationPolicy"] = "unreviewed";
        if (mutation == "previousNaturalPolicy") profile["naturalizationPolicy"] = "elbow-taubin12-3mm/v1";
        if (mutation == "reference") profile["referenceProfileSha256"] = new string('0', 64);
        if (mutation == "indices") profile["arms"][1]["indices"][0] = profile["arms"][0]["indices"][0].DeepClone();
        if (mutation == "angle") profile["arms"][0]["samples"][1]["flexDegrees"] = 0;
        if (mutation == "position") profile["arms"][0]["samples"][1]["deltaPositions"][0] = .1;
        if (mutation == "normal") profile["arms"][0]["samples"][1]["deltaNormals"][0] = 4;
        Type type = Helper.GetNestedType("Profile");
        object parsed = JsonUtility.FromJson(profile.ToString(), type);
        Assert.That(Static("ValidateProfile", parsed), Is.False);
    }

    [TestCase(-1f, 0, 0, 0f)] [TestCase(0f, 0, 0, 0f)]
    [TestCase(30f, 0, 1, .5f)] [TestCase(70f, 1, 2, .5f)] [TestCase(180f, 2, 2, 0f)]
    public void InterpolationNeverExtrapolatesBeyondAuthoredSampleDomain(float angle, int a, int b, float mix)
    {
        object[] args = { new[] { 20f, 40f, 100f }, angle, 0, 0, 0f };
        Helper.GetMethod("SelectKnots").Invoke(null, args);
        Assert.That(args[2], Is.EqualTo(a)); Assert.That(args[3], Is.EqualTo(b)); Assert.That((float)args[4], Is.EqualTo(mix).Within(.00001f));
    }

    [TestCase(-90f, 0f)] [TestCase(-70f, 0f)] [TestCase(-35f, 1f)]
    [TestCase(0f, 1f)] [TestCase(35f, 1f)] [TestCase(70f, 0f)] [TestCase(90f, 0f)]
    public void SourceCalibratedRelativeRollKeepsReviewedDomainAndRejectsUnsupportedPronation(float roll, float expected)
    {
        float actual = (float)Static("RollInfluence", Quaternion.identity, Quaternion.AngleAxis(roll, Vector3.up), Quaternion.identity, Vector3.up);
        Assert.That(actual, Is.EqualTo(expected).Within(.00001f));
        float left = (float)Static("RollInfluence", Quaternion.identity, Quaternion.AngleAxis(-60f, Vector3.up), Quaternion.identity, Vector3.up);
        float right = (float)Static("RollInfluence", Quaternion.identity, Quaternion.AngleAxis(60f, Vector3.up), Quaternion.identity, Vector3.up);
        Assert.That(left, Is.EqualTo(right).Within(.00001f));
        Assert.That(left, Is.InRange(.19f, .21f), "Transition remains gradual, rather than snapping at the threshold.");
    }

    [TestCase("L")] [TestCase("R")]
    public void ActualUnsupportedRollClearsOnlyOwnedShapesAndDoesNotWriteJoints(string side)
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        JObject sample = ((JArray)golden["samples"]).Cast<JObject>().Single(row => (string)row["side"] == side && (float)row["fkDegrees"] == 90f);
        var bones = f.Avatar.GetComponentsInChildren<Transform>(true).ToDictionary(t => t.name);
        foreach (var row in ((JObject)sample["bones"]).Properties().OrderBy(row => Depth(bones[row.Name])))
        {
            Matrix4x4 matrix = Matrix(row.Value);
            bones[row.Name].SetPositionAndRotation(matrix.GetColumn(3), Quaternion.LookRotation(matrix.GetColumn(2), matrix.GetColumn(1)));
        }
        f.Bind();
        string prefix = "Maaso.Joy.Elbow." + side + ".";
        int[] shapes = Enumerable.Range(0, f.Body.sharedMesh.blendShapeCount).Where(i => f.Body.sharedMesh.GetBlendShapeName(i).StartsWith(prefix, StringComparison.Ordinal)).ToArray();
        Assert.That(shapes.Sum(f.Body.GetBlendShapeWeight), Is.EqualTo(100f).Within(.001f));
        Transform forearm = bones["DEF-forearm." + side], hand = bones["DEF-hand." + side];
        Vector3 wrist = hand.position, axis = (wrist - forearm.position).normalized;
        Quaternion wristRotation = hand.rotation;
        forearm.rotation = Quaternion.AngleAxis(90f, axis) * forearm.rotation;
        hand.SetPositionAndRotation(wrist, wristRotation);
        var pose = bones.Values.ToDictionary(t => t, t => (t.localPosition, t.localRotation));
        Call(f.Component, "ApplyAfterVrm");
        Assert.That(shapes.Sum(f.Body.GetBlendShapeWeight), Is.Zero.Within(.00001f));
        foreach (var pair in pose)
        {
            Assert.That(pair.Key.localPosition, Is.EqualTo(pair.Value.localPosition));
            Assert.That(pair.Key.localRotation, Is.EqualTo(pair.Value.localRotation));
        }
    }

    private static float Percentile95(List<float> values)
    {
        float[] sorted = values.OrderBy(value => value).ToArray();
        return sorted[Mathf.FloorToInt((sorted.Length - 1) * .95f)];
    }

    private static int Depth(Transform value) { int depth = 0; while (value.parent != null) { value = value.parent; depth++; } return depth; }
    private static Matrix4x4 Matrix(JToken values)
    {
        var result = new Matrix4x4();
        for (int row = 0; row < 4; row++) for (int column = 0; column < 4; column++) result[row, column] = (float)values[row * 4 + column];
        return result;
    }
    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly SkinnedMeshRenderer Body;
        public readonly Behaviour Component;
        public Fixture()
        {
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Avatar.transform.localScale = Vector3.one;
            Avatar.GetComponent<Vrm10Instance>().enabled = false;
            Body = Avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(renderer => renderer.name == "Joy_body");
            Component = (Behaviour)Avatar.AddComponent(Helper);
        }
        public void Bind() => Assert.That(Call(Component, "Bind", Avatar.transform), Is.True, Helper.GetProperty("LastFailure").GetValue(Component) as string);
        public void Dispose() { Object.DestroyImmediate(Avatar); }
    }
}
