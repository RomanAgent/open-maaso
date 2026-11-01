using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class OpenAnnieNormalizedPoseTests
{
    private const string Source = "Assets/MaasoAvatar/Editor/OpenAnnieSource/";
    private const string Library = "Assets/MaasoAvatar/Resources/OpenAnnieMotionLibrary.asset";
    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static T Field<T>(object value, string name) => (T)value.GetType().GetField(name).GetValue(value);
    private static object[] Entries() => ((IEnumerable)TypeOf("OpenAnnieMotionLibrary").GetField("Entries")
        .GetValue(AssetDatabase.LoadAssetAtPath(Library, TypeOf("OpenAnnieMotionLibrary")))).Cast<object>().ToArray();

    [Test]
    public void AllSixtyThreeClipsPreserveEveryExactAndHalfFrameQuaternion()
    {
        JObject pack = JObject.Parse(File.ReadAllText(Source + "pack.json"));
        string packHash = Hash(File.ReadAllBytes(Source + "pack.json"));
        object[] entries = Entries();
        Assert.That(entries.Length, Is.EqualTo(63));
        int samples = 0;
        float maximumComponentError = 0f;
        double maximumAngularError = 0d;
        string worstSample = null;
        foreach (object entry in entries)
        {
            string name = Field<string>(entry, "Id").Substring(6);
            byte[] bytes = File.ReadAllBytes(Source + name + ".json");
            JObject data = JObject.Parse(System.Text.Encoding.UTF8.GetString(bytes));
            object clip = Field<object>(entry, "NormalizedPose");
            Assert.That(clip, Is.Not.Null, name + " must use the lossless path");
            Assert.That(Field<string>(clip, "SourceSha256"), Is.EqualTo(Hash(bytes)), name);
            Assert.That(Field<string>(clip, "SourcePackSha256"), Is.EqualTo(packHash), name);
            Assert.That(Field<string>(clip, "SourceCommit"), Is.EqualTo("1a3aebfe32343b119263c8b7eba3b7cb1d4e4507"));
            int frames = (int)data["frames"];
            bool loop = (bool)data["loop"];
            Dictionary<HumanBodyBones, Quaternion[]> original = OriginalTracks(data, (JObject)pack["hands"]);
            var sampler = clip.GetType().GetMethod("TrySample");
            object[] arguments = { HumanBodyBones.LeftUpperArm, 0f, Quaternion.identity };
            // Includes the loop seam and samples beyond duration to verify
            // wrap/clamp behaviour independently from Unity AnimationClip.
            for (int half = -2; half <= frames * 2 + 2; half++)
            {
                float seconds = half / 60f;
                foreach (var pair in original)
                {
                    arguments[0] = pair.Key;
                    arguments[1] = seconds;
                    Assert.That((bool)sampler.Invoke(clip, arguments), Is.True, name + "/" + pair.Key);
                    Quaternion expected = SampleOriginal(pair.Value, frames, loop, seconds);
                    Quaternion actual = (Quaternion)arguments[2];
                    float error = QuaternionDistance(expected, actual);
                    if (error > maximumComponentError)
                    { maximumComponentError = error; worstSample = name + "/" + pair.Key + " at " + seconds; }
                    maximumAngularError = Math.Max(maximumAngularError, AngularError(expected, actual));
                    samples++;
                }
            }
        }
        TestContext.WriteLine("Direct FK clips=63; exact+half-frame samples=" + samples +
            "; maximum sign-independent quaternion component error=" + maximumComponentError +
            "; maximum double-normalized angular error degrees=" + maximumAngularError + "; worst=" + worstSample);
        Assert.That(maximumComponentError, Is.LessThan(.000003f), worstSample);
        Assert.That(maximumAngularError, Is.LessThan(.001d), worstSample);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ActualJoyRawAndExistingControlRigKeepExactArmsAndUnownedChannels(bool useControlRig)
    {
        GameObject actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        var vrm = actor.GetComponent<Vrm10Instance>();
        var animator = actor.GetComponent<Animator>();
        vrm.enabled = false;
        animator.runtimeAnimatorController = null;
        animator.enabled = false;
        typeof(Vrm10Instance).GetField("m_useControlRig", BindingFlags.Instance | BindingFlags.NonPublic)
            .SetValue(vrm, useControlRig);
        bool oldIgnore = LogAssert.ignoreFailingMessages;
        object binding = Activator.CreateInstance(TypeOf("AvatarNormalizedArmPose"));
        var originalMaterials = actor.GetComponentsInChildren<Renderer>().ToDictionary(r => r, r => r.sharedMaterials);
        UnityEngine.Avatar generated = null;
        try
        {
            // Editor-imported UniVRM material cloning emits an editor-only
            // diagnostic; material ownership is restored below. No masking of
            // assertions or runtime pose failures.
            LogAssert.ignoreFailingMessages = true;
            Vrm10Runtime runtime = vrm.Runtime;
            LogAssert.ignoreFailingMessages = oldIgnore;
            generated = runtime.ControlRig?.ControlRigAnimator.avatar;
            UnityEngine.Avatar beforeAvatar = animator.avatar;
            Assert.That((bool)binding.GetType().GetMethod("Bind").Invoke(binding, new object[] { vrm, runtime }), Is.True);
            Assert.That(animator.avatar, Is.SameAs(beforeAvatar), "Binding cannot create/swap an Animator avatar");
            Assert.That((bool)binding.GetType().GetProperty("UsesControlRig").GetValue(binding), Is.EqualTo(useControlRig));
            Transform Bone(HumanBodyBones id) => useControlRig ? runtime.ControlRig.GetBoneTransform(id) :
                vrm.TryGetBoneTransform(id, out var raw) ? raw : null;
            var protectedBones = new[] { HumanBodyBones.Hips, HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg,
                HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg, HumanBodyBones.Neck, HumanBodyBones.Head,
                HumanBodyBones.Jaw, HumanBodyBones.LeftEye, HumanBodyBones.RightEye }
                .Select(Bone).Where(bone => bone != null).ToArray();
            var protectedPose = protectedBones.ToDictionary(b => b, b => (b.localPosition, b.localRotation, b.localScale));
            var initialRaw = new Dictionary<HumanBodyBones, (Quaternion local, Quaternion global)>();
            foreach (HumanBodyBones id in ArmBones())
            {
                Transform bone = Bone(id);
                if (bone != null) initialRaw.Add(id, (bone.localRotation, bone.rotation));
            }
            Vector3 initialPosition = actor.transform.position;
            Quaternion initialRotation = actor.transform.rotation;
            JObject pack = JObject.Parse(File.ReadAllText(Source + "pack.json"));
            float maximumComponentError = 0f;
            double maximumAngularError = 0d;
            string worstSample = null;
            int samples = 0;
            foreach (object entry in Entries())
            {
                string name = Field<string>(entry, "Id").Substring(6);
                JObject data = JObject.Parse(File.ReadAllText(Source + name + ".json"));
                var original = OriginalTracks(data, (JObject)pack["hands"]);
                int frames = (int)data["frames"];
                foreach (float time in new[] { 0f, 1f / 60f, (frames / 2 + .5f) / 30f, (frames - 1) / 30f })
                {
                    Assert.That((bool)binding.GetType().GetMethod("Apply").Invoke(binding,
                        new object[] { entry, time, 1f, false }), Is.True, name);
                    foreach (var pair in initialRaw)
                    {
                        Quaternion q = SampleOriginal(original[pair.Key], frames, (bool)data["loop"], time);
                        Quaternion expected = useControlRig ? q : pair.Value.local *
                            (Quaternion.Inverse(pair.Value.global) * q * pair.Value.global);
                        Quaternion actual = Bone(pair.Key).localRotation;
                        float error = QuaternionDistance(expected, actual);
                        if (error > maximumComponentError)
                        { maximumComponentError = error; worstSample = name + "/" + pair.Key + " at " + time; }
                        maximumAngularError = Math.Max(maximumAngularError, AngularError(expected, actual));
                        samples++;
                    }
                    foreach (var pair in protectedPose)
                    {
                        Assert.That(Vector3.Distance(pair.Key.localPosition, pair.Value.localPosition), Is.LessThan(.000001f));
                        Assert.That(QuaternionDistance(pair.Key.localRotation, pair.Value.localRotation), Is.LessThan(.000001f));
                        Assert.That(pair.Key.localScale, Is.EqualTo(pair.Value.localScale));
                    }
                    binding.GetType().GetMethod("RestoreOwnedPose").Invoke(binding, null);
                    foreach (var pair in initialRaw)
                        Assert.That(QuaternionDistance(Bone(pair.Key).localRotation, pair.Value.local), Is.LessThan(.000003f));
                }
            }
            Assert.That(actor.transform.position, Is.EqualTo(initialPosition));
            Assert.That(actor.transform.rotation, Is.EqualTo(initialRotation));
            TestContext.WriteLine("Joy direct FK controlRig=" + useControlRig + "; clips=63; bone samples=" + samples +
                "; maximum component error=" + maximumComponentError + "; maximum double-normalized angular error degrees=" +
                maximumAngularError + "; worst=" + worstSample);
            Assert.That(maximumComponentError, Is.LessThan(.000003f), worstSample);
            Assert.That(maximumAngularError, Is.LessThan(.001d), worstSample);

            object one = Entries()[0];
            binding.GetType().GetMethod("Apply").Invoke(binding, new object[] { one, .25f, 1f, false });
            Transform hand = Bone(HumanBodyBones.LeftHand);
            Quaternion takeover = Quaternion.AngleAxis(23f, Vector3.up) * hand.localRotation;
            hand.localRotation = takeover;
            binding.GetType().GetMethod("Release").Invoke(binding, null);
            Assert.That(QuaternionDistance(hand.localRotation, takeover), Is.LessThan(.000001f),
                "Task/phone/desk pose that supersedes the source write must survive release");
        }
        finally
        {
            LogAssert.ignoreFailingMessages = oldIgnore;
            binding.GetType().GetMethod("Release").Invoke(binding, null);
            foreach (var pair in originalMaterials)
                if (pair.Key != null)
                {
                    var created = pair.Key.sharedMaterials;
                    pair.Key.sharedMaterials = pair.Value;
                    foreach (Material material in created)
                        if (material != null && !pair.Value.Contains(material) && !EditorUtility.IsPersistent(material)) Object.DestroyImmediate(material);
                }
            Object.DestroyImmediate(actor);
            if (generated != null) Object.DestroyImmediate(generated);
        }
    }

    [Test]
    public void NonVrmFallbackNeverClaimsDirectPoseOwnership()
    {
        object binding = Activator.CreateInstance(TypeOf("AvatarNormalizedArmPose"));
        Assert.That((bool)binding.GetType().GetMethod("Bind").Invoke(binding, new object[] { null, null }), Is.False);
        Assert.That((bool)binding.GetType().GetMethod("Apply").Invoke(binding,
            new object[] { Entries()[0], .2f, 1f, true }), Is.False);
        Assert.That((bool)binding.GetType().GetProperty("HasOwnedWrites").GetValue(binding), Is.False);
    }

    private static Dictionary<HumanBodyBones, Quaternion[]> OriginalTracks(JObject data, JObject hands)
    {
        var result = ArmBones().Concat(new[] { HumanBodyBones.Spine, HumanBodyBones.Chest, HumanBodyBones.UpperChest })
            .ToDictionary(id => id, _ => new[] { Quaternion.identity });
        foreach (JProperty source in hands.Properties())
            if (Map(source.Name, out var id) && result.ContainsKey(id)) result[id] = Convert(source.Value.ToObject<float[]>());
        foreach (JProperty source in ((JObject)data["bones"]).Properties())
            if (Map(source.Name, out var id) && result.ContainsKey(id)) result[id] = Convert(source.Value.ToObject<float[]>());
        return result;
    }

    private static IEnumerable<HumanBodyBones> ArmBones() => Enum.GetValues(typeof(HumanBodyBones)).Cast<HumanBodyBones>()
        .Where(id => id is HumanBodyBones.LeftShoulder or HumanBodyBones.RightShoulder or
            HumanBodyBones.LeftUpperArm or HumanBodyBones.RightUpperArm or HumanBodyBones.LeftLowerArm or
            HumanBodyBones.RightLowerArm or HumanBodyBones.LeftHand or HumanBodyBones.RightHand ||
            id >= HumanBodyBones.LeftThumbProximal && id <= HumanBodyBones.RightLittleDistal);

    private static bool Map(string name, out HumanBodyBones id)
    {
        if (name.EndsWith("ThumbMetacarpal", StringComparison.Ordinal)) name = name.Replace("ThumbMetacarpal", "ThumbProximal");
        else if (name.EndsWith("ThumbProximal", StringComparison.Ordinal)) name = name.Replace("ThumbProximal", "ThumbIntermediate");
        return Enum.TryParse(name, true, out id);
    }

    private static Quaternion[] Convert(float[] source)
    {
        var result = new Quaternion[source.Length / 4];
        for (int frame = 0; frame < result.Length; frame++)
        {
            int i = frame * 4;
            result[frame] = new Quaternion(source[i], -source[i + 1], -source[i + 2], source[i + 3]).normalized;
        }
        return result;
    }

    private static Quaternion SampleOriginal(Quaternion[] source, int frames, bool loop, float seconds)
    {
        if (source.Length == 1) return source[0];
        double x = (double)seconds * 30d;
        x = loop ? ((x % frames) + frames) % frames : Math.Min(Math.Max(x, 0d), frames - 1);
        int a = (int)Math.Floor(x), b = loop ? (a + 1) % frames : Math.Min(a + 1, frames - 1);
        return Quaternion.SlerpUnclamped(source[a], source[b], (float)(x - a));
    }

    private static float QuaternionDistance(Quaternion a, Quaternion b)
    {
        if (Quaternion.Dot(a, b) < 0f) b = new Quaternion(-b.x, -b.y, -b.z, -b.w);
        return Mathf.Max(Mathf.Abs(a.x - b.x), Mathf.Abs(a.y - b.y), Mathf.Abs(a.z - b.z), Mathf.Abs(a.w - b.w));
    }

    private static double AngularError(Quaternion a, Quaternion b)
    {
        // Unity Quaternion.Angle uses float dot products and has a rounding
        // floor near identity. Normalize and compare in double for this gate.
        double dot = (double)a.x * b.x + (double)a.y * b.y + (double)a.z * b.z + (double)a.w * b.w;
        double aa = (double)a.x * a.x + (double)a.y * a.y + (double)a.z * a.z + (double)a.w * a.w;
        double bb = (double)b.x * b.x + (double)b.y * b.y + (double)b.z * b.z + (double)b.w * b.w;
        return 2d * Math.Acos(Math.Min(1d, Math.Abs(dot) / Math.Sqrt(aa * bb))) * 180d / Math.PI;
    }

    private static string Hash(byte[] bytes)
    {
        using var sha = SHA256.Create();
        return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }
}
