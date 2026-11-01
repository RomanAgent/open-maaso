using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public sealed class UnityAvatarCommandReceiverTests
{
    private const string ComponentTypeName = "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp";
    private const string FrontFullBodyCameraTypeName = "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp";

    [Test]
    public void BundledAvatarLoadResultOmitsAbsentCapabilityProfile()
    {
        string json = SerializeAvatarLoadResult(capabilityProfile: null);

        Assert.That(json, Does.Contain("\"method\":\"loadAvatar\""));
        Assert.That(json, Does.Not.Contain("\"capabilityProfile\""));
        Assert.That(json, Does.Not.Contain("\"schemaVersion\":0"));
    }

    [Test]
    public void ReviewedAvatarLoadResultKeepsAuthoritativeCapabilityProfile()
    {
        var candidate = new GameObject("Capability Candidate");
        try
        {
            Type probeType = Type.GetType(
                "Maaso.Avatar.AvatarCapabilityProbe, Assembly-CSharp");
            Assert.That(probeType, Is.Not.Null);
            MethodInfo probe = probeType.GetMethod(
                "ProbeCandidate",
                BindingFlags.Public | BindingFlags.Static);
            Assert.That(probe, Is.Not.Null);
            object profile = probe.Invoke(null, new object[] { candidate });

            string json = SerializeAvatarLoadResult(profile);

            Assert.That(json, Does.Contain("\"capabilityProfile\""));
            Assert.That(json, Does.Contain("\"schemaVersion\":1"));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(candidate);
        }
    }

    [Test]
    public void SetMouthOpenCommandDrivesVisemeBlendShapes()
    {
        using var fixture = AvatarFixture.Create("A", "Jaw", "mouthOpen1", "mouthOpen2", "Facial_Blends.Jaw_Down");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(receiver, "setMouthOpen", "{\"value\":0.72}");

        Assert.That(fixture.Weight("A"), Is.GreaterThan(65f));
        Assert.That(fixture.Weight("mouthOpen1"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("mouthOpen2"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("Jaw"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("Facial_Blends.Jaw_Down"), Is.EqualTo(0f));
    }

    [Test]
    public void ModularAnimeMouthAliasPrefersVisibleAhPhoneme()
    {
        using var fixture = AvatarFixture.Create("phoneme_Ah", "jaw_open");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(receiver, "setMouthOpen", "{\"value\":0.72}");

        Assert.That(fixture.Weight("phoneme_Ah"), Is.GreaterThan(65f));
        Assert.That(fixture.Weight("jaw_open"), Is.EqualTo(0f));
    }

    [Test]
    public void NativeSpeechCombinesSharedSourceMorphsWithoutClearingThem()
    {
        using var fixture = AvatarFixture.Create(
            "V_Open", "V_Wide", "V_Tight", "V_Tight_O", "V_Explosive",
            "V_Dental_Lip", "Fcl_MTH_A", "Fcl_MTH_I");
        Component receiver = fixture.AddReceiver();

        InvokeReceiverPrivate(receiver, "SetNonVrmMouthVisemes",
            .4f, .6f, 0f, .2f, 0f);

        Assert.That(fixture.Weight("V_Open"), Is.EqualTo(53.2f).Within(.001f));
        Assert.That(fixture.Weight("V_Wide"), Is.EqualTo(58f).Within(.001f));
        Assert.That(fixture.Weight("Fcl_MTH_A"), Is.Zero);
        Assert.That(fixture.Weight("Fcl_MTH_I"), Is.Zero);

        SetField(receiver, "mouthVisemePp", .5f);
        InvokeReceiverPrivate(receiver, "SetNonVrmMouthVisemes",
            .4f, .6f, 0f, .2f, 0f);
        Assert.That(fixture.Weight("V_Explosive"), Is.EqualTo(50f).Within(.001f));
        Assert.That(fixture.Weight("V_Open"), Is.Zero);
        Assert.That(fixture.Weight("V_Wide"), Is.Zero);
    }

    [Test]
    public void NativeFaceMorphsAreRecognizedByCapabilityProbe()
    {
        var root = new GameObject("NativeFaceProbe");
        var faceObject = new GameObject("Face");
        faceObject.transform.SetParent(root.transform, false);
        SkinnedMeshRenderer face = faceObject.AddComponent<SkinnedMeshRenderer>();
        face.sharedMesh = CreateBlendShapeMesh(
            "V_Open", "V_Wide", "V_Tight", "V_Tight_O", "V_Explosive",
            "V_Dental_Lip", "Eye_Blink_L", "Eye_Blink_R",
            "Mouth_Smile_L", "Mouth_Smile_R", "Brow_Raise_Inner_L",
            "Brow_Drop_L", "Eye_Squint_L", "Brow_Raise_Outer_L", "Eye_Wide_L");
        try
        {
            Type probe = Type.GetType("Maaso.Avatar.AvatarCapabilityProbe, Assembly-CSharp", true);
            object profile = probe.GetMethod("ProbeCandidate").Invoke(null, new object[] { root });
            string json = JsonUtility.ToJson(profile);
            Assert.That(json, Does.Contain("\"lipSync\":true"));
            Assert.That(json, Does.Contain("\"blink\":true"));
            Assert.That(json, Does.Contain("\"expressions\":true"));
        }
        finally { UnityEngine.Object.DestroyImmediate(root); }
    }

    [Test]
    public void LegacyLipSyncStillUsesAaAndBoostsQuietSpeech()
    {
        using var fixture = AvatarFixture.Create("A", "I");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "startLipSync",
            "{\"envelope\":[0.2,0.2],\"frameRate\":30}");

        Assert.That(fixture.Weight("A"), Is.GreaterThan(35f));
        Assert.That(fixture.Weight("I"), Is.LessThan(1f));

        InvokeCommand(receiver, "stopLipSync", "{}");

        Assert.That(fixture.Weight("A"), Is.LessThan(1f));
        Assert.That(fixture.Weight("I"), Is.LessThan(1f));
    }

    [Test]
    public void VisemeTimelineSelectsFiveVowelsCrossFadesAndStopsCleanly()
    {
        using var fixture = AvatarFixture.Create("A", "I", "U", "E", "O");
        Component receiver = fixture.AddReceiver();
        const string timeline =
            "{\"format\":\"vrm_viseme_v2\"," +
            "\"envelope\":[0.2,0.2,0.2,0.2,0.2,0.2,0.2,0.2,0.2,0.2,0.2]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"aa\"}," +
            "{\"frame\":2,\"viseme\":\"ih\"}," +
            "{\"frame\":4,\"viseme\":\"ou\"}," +
            "{\"frame\":6,\"viseme\":\"ee\"}," +
            "{\"frame\":8,\"viseme\":\"oh\"}," +
            "{\"frame\":10,\"viseme\":\"sil\"}],\"frameRate\":30}";

        InvokeCommand(receiver, "startVisemeTimeline", timeline);
        AssertActiveVowel(fixture, "A");
        InvokeApplyLipSyncFrame(receiver, 2f);
        AssertActiveVowel(fixture, "I");
        InvokeApplyLipSyncFrame(receiver, 4f);
        AssertActiveVowel(fixture, "U");
        InvokeApplyLipSyncFrame(receiver, 6f);
        AssertActiveVowel(fixture, "E");
        InvokeApplyLipSyncFrame(receiver, 8f);
        AssertActiveVowel(fixture, "O");

        InvokeCommand(
            receiver,
            "startVisemeTimeline",
            "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2,0.2,0.2,0.2,0.2]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"aa\"}," +
            "{\"frame\":4,\"viseme\":\"ih\"}],\"frameRate\":30}");
        InvokeApplyLipSyncFrame(receiver, 3f);
        Assert.That(fixture.Weight("A"), Is.GreaterThan(15f));
        Assert.That(fixture.Weight("I"), Is.GreaterThan(15f));

        InvokeCommand(receiver, "stopLipSync", "{}");
        foreach (string vowel in new[] { "A", "I", "U", "E", "O" })
        {
            Assert.That(fixture.Weight(vowel), Is.LessThan(1f));
        }
    }

    [Test]
    public void NonVrmVisemesUseFclAndVrcAliasesThenFallBackToJaw()
    {
        using var fixture = AvatarFixture.Create(
            "Fcl_MTH_I",
            "vrc.v_ou",
            "jaw_open");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "startVisemeTimeline",
            SingleVisemeTimeline("ih"));
        Assert.That(fixture.Weight("Fcl_MTH_I"), Is.GreaterThan(35f));
        Assert.That(fixture.Weight("vrc.v_ou"), Is.LessThan(1f));
        Assert.That(fixture.Weight("jaw_open"), Is.LessThan(1f));

        InvokeCommand(
            receiver,
            "startVisemeTimeline",
            SingleVisemeTimeline("ou"));
        Assert.That(fixture.Weight("Fcl_MTH_I"), Is.LessThan(1f));
        Assert.That(fixture.Weight("vrc.v_ou"), Is.GreaterThan(35f));
        Assert.That(fixture.Weight("jaw_open"), Is.LessThan(1f));

        InvokeCommand(
            receiver,
            "startVisemeTimeline",
            SingleVisemeTimeline("oh"));
        Assert.That(fixture.Weight("Fcl_MTH_I"), Is.LessThan(1f));
        Assert.That(fixture.Weight("vrc.v_ou"), Is.LessThan(1f));
        Assert.That(fixture.Weight("jaw_open"), Is.GreaterThan(35f));
    }

    [Test]
    public void PartialVrmVisemesFallBackToSiblingVowelThenAa()
    {
        Type receiverType = Type.GetType(ComponentTypeName);
        Assert.That(receiverType, Is.Not.Null);
        MethodInfo resolve = receiverType.GetMethod(
            "ResolveVrmVisemeWeights",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(resolve, Is.Not.Null);

        object siblingFallback = resolve.Invoke(
            null,
            new object[]
            {
                new[] { ExpressionKey.Aa, ExpressionKey.Ee, ExpressionKey.Oh },
                0f,
                0f,
                0.4f,
                0.3f,
                0f,
                0f,
            });
        Assert.That(VisemeWeight(siblingFallback, "aa"), Is.EqualTo(0f));
        Assert.That(VisemeWeight(siblingFallback, "ih"), Is.EqualTo(0f));
        Assert.That(VisemeWeight(siblingFallback, "ou"), Is.EqualTo(0f));
        Assert.That(
            VisemeWeight(siblingFallback, "ee"),
            Is.EqualTo(0.4f).Within(0.001f));
        Assert.That(
            VisemeWeight(siblingFallback, "oh"),
            Is.EqualTo(0.3f).Within(0.001f));

        object aaFallback = resolve.Invoke(
            null,
            new object[]
            {
                new[] { ExpressionKey.Aa },
                0f,
                0f,
                0.4f,
                0.3f,
                0f,
                0f,
            });
        Assert.That(
            VisemeWeight(aaFallback, "aa"),
            Is.EqualTo(0.7f).Within(0.001f));
        foreach (string viseme in new[] { "ih", "ou", "ee", "oh" })
        {
            Assert.That(VisemeWeight(aaFallback, viseme), Is.EqualTo(0f));
        }
    }

    [Test]
    public void ModularAnimeBlinkAliasClosesAllEyeVariants()
    {
        using var fixture = AvatarFixture.Create(
            "eyes_closed.01",
            "eyes_closed.02",
            "eyes_closed.03");
        Component receiver = fixture.AddReceiver();

        SetField(receiver, "nextBlinkAt", Time.realtimeSinceStartup - 0.01f);
        SetField(receiver, "blinkStartedAt", -1f);
        InvokeUpdateAutoBlink(receiver);
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt",
            Field<float>(receiver, "blinkStartedAt") + 0.16f * 0.35f);

        Assert.That(fixture.Weight("eyes_closed.01"), Is.GreaterThan(95f));
        Assert.That(fixture.Weight("eyes_closed.02"), Is.GreaterThan(95f));
        Assert.That(fixture.Weight("eyes_closed.03"), Is.GreaterThan(95f));
    }

    [Test]
    public void ReceiverAutoSelectsModularAnimeFaceRenderer()
    {
        var root = new GameObject("AvatarRoot");
        var bodyObject = new GameObject("Body");
        var faceObject = new GameObject("Face");
        bodyObject.transform.SetParent(root.transform, false);
        faceObject.transform.SetParent(root.transform, false);
        SkinnedMeshRenderer body = bodyObject.AddComponent<SkinnedMeshRenderer>();
        body.sharedMesh = CreateBlendShapeMesh("clothFold");
        SkinnedMeshRenderer face = faceObject.AddComponent<SkinnedMeshRenderer>();
        face.sharedMesh = CreateBlendShapeMesh("jaw_open", "eyes_closed.01");

        try
        {
            Type componentType = Type.GetType(ComponentTypeName);
            Assert.That(componentType, Is.Not.Null);
            Component receiver = root.AddComponent(componentType);
            SetField(receiver, "avatarRoot", root.transform);
            SetField(receiver, "faceRenderer", null);

            MethodInfo ensureAvatar = componentType.GetMethod(
                "EnsureAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(ensureAvatar, Is.Not.Null);
            ensureAvatar.Invoke(receiver, Array.Empty<object>());
            InvokeCommand(receiver, "setMouthOpen", "{\"value\":0.72}");

            Assert.That(
                face.GetBlendShapeWeight(
                    face.sharedMesh.GetBlendShapeIndex("jaw_open")),
                Is.GreaterThan(65f));
            Assert.That(Field<SkinnedMeshRenderer>(receiver, "faceRenderer"), Is.SameAs(face));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    [Test]
    public void ReceiverAutoSelectsNativeFaceRatherThanClothing()
    {
        var root = new GameObject("NativeFaceRoot");
        var clothingObject = new GameObject("Shirt");
        var faceObject = new GameObject("CC_Base_Body");
        clothingObject.transform.SetParent(root.transform, false);
        faceObject.transform.SetParent(root.transform, false);
        SkinnedMeshRenderer clothing = clothingObject.AddComponent<SkinnedMeshRenderer>();
        clothing.sharedMesh = CreateBlendShapeMesh("clothFold");
        SkinnedMeshRenderer face = faceObject.AddComponent<SkinnedMeshRenderer>();
        face.sharedMesh = CreateBlendShapeMesh("V_Open", "V_Wide", "V_Tight",
            "V_Tight_O", "V_Explosive", "V_Dental_Lip", "Eye_Blink_L");
        try
        {
            Type type = Type.GetType(ComponentTypeName, true);
            Component receiver = root.AddComponent(type);
            SetField(receiver, "avatarRoot", root.transform);
            SetField(receiver, "faceRenderer", null);
            InvokeReceiverPrivate(receiver, "EnsureAvatar");
            InvokeCommand(receiver, "setMouthOpen", "{\"value\":0.72}");
            Assert.That(Field<SkinnedMeshRenderer>(receiver, "faceRenderer"), Is.SameAs(face));
            Assert.That(face.GetBlendShapeWeight(face.sharedMesh.GetBlendShapeIndex("V_Open")),
                Is.GreaterThan(65f));
        }
        finally { UnityEngine.Object.DestroyImmediate(root); }
    }

    [Test]
    public void ReceiverAutoSelectsRendererWithFacialBlendShapes()
    {
        var root = new GameObject("AvatarRoot");
        var bodyObject = new GameObject("Body");
        var faceObject = new GameObject("Face");
        bodyObject.transform.SetParent(root.transform, false);
        faceObject.transform.SetParent(root.transform, false);
        SkinnedMeshRenderer body = bodyObject.AddComponent<SkinnedMeshRenderer>();
        body.sharedMesh = CreateBlendShapeMesh("clothFold");
        SkinnedMeshRenderer face = faceObject.AddComponent<SkinnedMeshRenderer>();
        face.sharedMesh = CreateBlendShapeMesh("A", "mouthOpen1", "Blink", "Blink1_L", "Blink1_R");

        try
        {
            Type componentType = Type.GetType(ComponentTypeName);
            Assert.That(componentType, Is.Not.Null, "Unity avatar command receiver should exist.");
            Component receiver = root.AddComponent(componentType);
            SetField(receiver, "avatarRoot", root.transform);

            MethodInfo ensureAvatar = componentType.GetMethod(
                "EnsureAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(ensureAvatar, Is.Not.Null);
            ensureAvatar.Invoke(receiver, Array.Empty<object>());

            InvokeCommand(receiver, "setMouthOpen", "{\"value\":0.72}");

            Assert.That(face.GetBlendShapeWeight(face.sharedMesh.GetBlendShapeIndex("A")), Is.GreaterThan(65f));
            Assert.That(face.GetBlendShapeWeight(face.sharedMesh.GetBlendShapeIndex("mouthOpen1")), Is.EqualTo(0f));
            Assert.That(body.GetBlendShapeWeight(body.sharedMesh.GetBlendShapeIndex("clothFold")), Is.EqualTo(0f));
            Assert.That(Field<SkinnedMeshRenderer>(receiver, "faceRenderer"), Is.SameAs(face));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    [Test]
    public void SetExpressionCommandMapsEmotionParamsToFaceBlendShapes()
    {
        using var fixture = AvatarFixture.Create("Fun", "Smile_L", "Smile_R", "Angry", "Blink");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "setExpression",
            "{\"happy\":0.8,\"mouthSmile\":0.6,\"angry\":0.25,\"eyeOpen\":0.4}");
        CompleteExpressionTransition(receiver);

        Assert.That(fixture.Weight("Fun"), Is.GreaterThan(70f));
        Assert.That(fixture.Weight("Smile_L"), Is.GreaterThan(50f));
        Assert.That(fixture.Weight("Smile_R"), Is.GreaterThan(50f));
        Assert.That(fixture.Weight("Angry"), Is.InRange(20f, 30f));
        Assert.That(fixture.Weight("Blink"), Is.GreaterThan(50f));
    }

    [Test]
    public void ExpressionTransitionCanBeInterruptedFromItsCurrentPose()
    {
        using var fixture = AvatarFixture.Create("Fun", "tareme");
        Component receiver = fixture.AddReceiver();
        InvokeCommand(receiver, "setExpression", "{\"happy\":1,\"eyeOpen\":1}");
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(0f));

        float startedAt = Field<float>(receiver, "expressionTransitionStartedAt");
        InvokeReceiverPrivate(receiver, "UpdateExpressionTransition", startedAt + 0.11f);
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(50f).Within(0.1f));

        // Rebase the deterministic sample to the real clock before interrupting it.
        SetField(receiver, "expressionTransitionStartedAt", Time.realtimeSinceStartup - 0.11f);
        InvokeCommand(receiver, "setExpression", "{\"sad\":0.8,\"eyeOpen\":1}");
        float interruptedWeight = fixture.Weight("Fun");
        Assert.That(interruptedWeight, Is.EqualTo(50f).Within(1f));
        Assert.That(fixture.Weight("tareme"), Is.EqualTo(0f));

        startedAt = Field<float>(receiver, "expressionTransitionStartedAt");
        InvokeReceiverPrivate(receiver, "UpdateExpressionTransition", startedAt + 0.11f);
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(interruptedWeight * 0.5f).Within(0.1f));
        Assert.That(fixture.Weight("tareme"), Is.EqualTo(40f).Within(0.1f));
        CompleteExpressionTransition(receiver);
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("tareme"), Is.EqualTo(80f).Within(0.01f));
    }

    [Test]
    public void ExpressionSpeechAndBlinkChannelsRemainIndependent()
    {
        using var fixture = AvatarFixture.Create("Fun", "A", "I", "Blink");
        Component receiver = fixture.AddReceiver();
        InvokeCommand(receiver, "startVisemeTimeline",
            "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"ih\"}],\"frameRate\":30}");
        float speechWeight = fixture.Weight("I");
        InvokeCommand(receiver, "setExpression",
            "{\"happy\":0.75,\"mouthOpen\":1,\"eyeOpen\":1}");
        CompleteExpressionTransition(receiver);
        SetField(receiver, "nextBlinkAt", 10f);
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10f);
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.056f);

        Assert.That(Field<bool>(receiver, "lipSyncActive"), Is.True);
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(75f).Within(0.01f));
        Assert.That(fixture.Weight("I"), Is.EqualTo(speechWeight).Within(0.01f));
        Assert.That(fixture.Weight("A"), Is.EqualTo(0f), "Emotion must not add a static open-mouth floor to TTS.");
        Assert.That(fixture.Weight("Blink"), Is.GreaterThan(99f));

        InvokeApplyLipSyncFrame(receiver, 1f);
        Assert.That(fixture.Weight("I"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("A"), Is.EqualTo(0f), "A silent TTS frame still owns the mouth.");
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(75f).Within(0.01f));
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.16f);
        Assert.That(fixture.Weight("Blink"), Is.LessThan(0.01f));
    }

    [Test]
    public void TicketedMouthCommandMutatesOnlyAfterReceiverValidation()
    {
        using var fixture = AvatarFixture.Create("A");
        Component receiver = fixture.AddReceiver();
        string rendererPayload = "{\"channel\":\"mouth\",\"value\":0.72}";

        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(rendererPayload, ticket: 1));

        Assert.That(fixture.Weight("A"), Is.GreaterThan(65f));
        Assert.That(
            Field<long>(receiver, "avatarArbiterRendererGenerationHighWater"),
            Is.EqualTo(1L));
    }

    [Test]
    public void TicketedVisemeTimelineAcceptsV2AndRejectsMalformedCues()
    {
        using var fixture = AvatarFixture.Create("A", "I");
        Component receiver = fixture.AddReceiver();
        const string valid =
            "{\"channel\":\"mouth\",\"format\":\"vrm_viseme_v2\"," +
            "\"envelope\":[0.2,0.2]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"ih\"}]," +
            "\"frameRate\":30}";

        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(valid, ticket: 1));

        Assert.That(fixture.Weight("I"), Is.GreaterThan(35f));
        Assert.That(fixture.Weight("A"), Is.LessThan(1f));

        string[] rejected =
        {
            valid.Replace("\"frameRate\":30", "\"extra\":true,\"frameRate\":30"),
            valid.Replace("\"viseme\":\"ih\"", "\"viseme\":\"ih\",\"extra\":true"),
            valid.Replace("\"frame\":0", "\"frame\":1"),
            valid.Replace("\"viseme\":\"ih\"", "\"viseme\":\"wide\""),
            valid.Replace("\"vrm_viseme_v2\"", "\"vrm_viseme_v3\""),
            "{\"channel\":\"mouth\",\"format\":\"vrm_viseme_v2\"," +
                "\"envelope\":[0.2,0.2]," +
                "\"cues\":[{\"frame\":0,\"viseme\":\"aa\"}," +
                "{\"frame\":0,\"viseme\":\"ih\"}],\"frameRate\":30}",
            "{\"channel\":\"mouth\",\"format\":\"vrm_viseme_v2\"," +
                "\"envelope\":[0.2,0.2]," +
                "\"cues\":[{\"frame\":0,\"viseme\":\"aa\"}," +
                "{\"frame\":2,\"viseme\":\"ih\"}],\"frameRate\":30}",
        };
        for (int index = 0; index < rejected.Length; index++)
        {
            InvokeCommand(
                receiver,
                "avatarArbiterCommand",
                ArbiterCommandJson(rejected[index], ticket: index + 2));
            Assert.That(fixture.Weight("I"), Is.GreaterThan(35f));
            Assert.That(fixture.Weight("A"), Is.LessThan(1f));
        }
    }

    [Test]
    public void TicketedCommandRejectsForgedDigestStaleTicketAndExpressionMouth()
    {
        using var fixture = AvatarFixture.Create("A", "Fun");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(
                "{\"channel\":\"mouth\",\"value\":0.7}",
                ticket: 2));
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));

        string stale = ArbiterCommandJson(
            "{\"channel\":\"mouth\",\"value\":0.1}",
            ticket: 1);
        InvokeCommand(receiver, "avatarArbiterCommand", stale);
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));

        string expression =
            "{\"channel\":\"expression\",\"params\":{" +
            "\"happy\":1.0,\"mouthOpen\":0.9,\"eyeOpen\":1.0}}";
        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(expression, ticket: 3, channel: "expression"));
        Assert.That(fixture.Weight("Fun"), Is.LessThan(1f));

        string forged = ArbiterCommandJson(
            "{\"channel\":\"mouth\",\"value\":0.0}",
            ticket: 4).Replace(
                "\"payloadSha256\":\"",
                "\"payloadSha256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
        InvokeCommand(receiver, "avatarArbiterCommand", forged);
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));
    }

    [Test]
    public void TicketedCommandRejectsUnknownDuplicateAndWrongTypedFields()
    {
        using var fixture = AvatarFixture.Create("A");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(
                "{\"channel\":\"mouth\",\"value\":0.7}",
                ticket: 1));
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));

        string[] rejectedPayloads =
        {
            "{\"channel\":\"mouth\",\"value\":0.1,\"unexpected\":true}",
            "{\"channel\":\"mouth\",\"value\":0.1,\"value\":0.2}",
            "{\"channel\":\"mouth\",\"value\":\"0.1\"}",
        };
        for (int index = 0; index < rejectedPayloads.Length; index++)
        {
            InvokeCommand(
                receiver,
                "avatarArbiterCommand",
                ArbiterCommandJson(rejectedPayloads[index], ticket: index + 2));
            Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));
        }

        string duplicateOuterField = ArbiterCommandJson(
            "{\"channel\":\"mouth\",\"value\":0.1}",
            ticket: 5).Replace(
                "\"ticket\":5,",
                "\"ticket\":5,\"ticket\":6,");
        InvokeCommand(receiver, "avatarArbiterCommand", duplicateOuterField);
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));
    }

    [Test]
    public void TicketedCommandRejectsCaseAliasedFieldsAndTrailingJson()
    {
        using var fixture = AvatarFixture.Create("A");
        Component receiver = fixture.AddReceiver();
        string valid = ArbiterCommandJson(
            "{\"channel\":\"mouth\",\"value\":0.7}",
            ticket: 1);

        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            valid.Replace("\"ticket\":1,", "\"Ticket\":1,"));
        InvokeCommand(receiver, "avatarArbiterCommand", valid + "{}");

        Assert.That(fixture.Weight("A"), Is.LessThan(1f));
        Assert.That(
            Field<string>(receiver, "avatarArbiterOwnerToken"),
            Is.Empty);
        Assert.That(
            Field<long>(receiver, "avatarArbiterRendererGenerationHighWater"),
            Is.EqualTo(-1L));
    }

    [Test]
    public void TicketedResetRejectsUnknownFieldsWithoutOwnerTransfer()
    {
        using var fixture = AvatarFixture.Create("A");
        Component receiver = fixture.AddReceiver();
        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(
                "{\"channel\":\"mouth\",\"value\":0.7}",
                ticket: 1));

        string resetWithUnknownField = ArbiterResetJson().Replace(
            "\"deadlineEpochMs\":",
            "\"unexpected\":true,\"deadlineEpochMs\":");
        InvokeCommand(
            receiver,
            "avatarArbiterReset",
            resetWithUnknownField);

        Assert.That(
            Field<string>(receiver, "avatarArbiterOwnerToken"),
            Is.EqualTo(new string('A', 43)));
        Assert.That(
            Field<long>(receiver, "avatarArbiterRendererGeneration"),
            Is.EqualTo(1L));
    }

    [Test]
    public void TicketedResetRejectsMismatchedRetiredOwnerScopeWithoutMutation()
    {
        using var fixture = AvatarFixture.Create("A");
        Component receiver = fixture.AddReceiver();
        InvokeCommand(
            receiver,
            "avatarArbiterCommand",
            ArbiterCommandJson(
                "{\"channel\":\"mouth\",\"value\":0.7}",
                ticket: 1));
        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));

        string wrongAccount = ArbiterResetJson().Replace(
            "\"retiredAccountGeneration\":7",
            "\"retiredAccountGeneration\":6");
        InvokeCommand(receiver, "avatarArbiterReset", wrongAccount);
        string wrongRenderer = ArbiterResetJson().Replace(
            "\"retiredRendererGeneration\":1",
            "\"retiredRendererGeneration\":0");
        InvokeCommand(receiver, "avatarArbiterReset", wrongRenderer);

        Assert.That(fixture.Weight("A"), Is.GreaterThan(60f));
        Assert.That(
            Field<string>(receiver, "avatarArbiterOwnerToken"),
            Is.EqualTo(new string('A', 43)));
        Assert.That(
            Field<long>(receiver, "avatarArbiterAccountGeneration"),
            Is.EqualTo(7L));
        Assert.That(
            Field<long>(receiver, "avatarArbiterRendererGeneration"),
            Is.EqualTo(1L));
    }

    [Test]
    public void TicketedResetNeutralizesRendererBeforeOwnerTransfer()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        using var fixture = AvatarFixture.Create("A");
        var cameraObject = new GameObject("Main Camera");
        try
        {
            cameraObject.tag = "MainCamera";
            cameraObject.AddComponent<Camera>();
            Type framingType = Type.GetType(FrontFullBodyCameraTypeName);
            Assert.That(framingType, Is.Not.Null);
            cameraObject.AddComponent(framingType);
            Component receiver = fixture.AddReceiver();
            InvokeCommand(
                receiver,
                "avatarArbiterCommand",
                ArbiterCommandJson(
                    "{\"channel\":\"mouth\",\"value\":0.8}",
                    ticket: 1));
            Assert.That(fixture.Weight("A"), Is.GreaterThan(70f));

            InvokeCommand(receiver, "avatarArbiterReset", ArbiterResetJson());

            Assert.That(fixture.Weight("A"), Is.LessThan(1f));
            Assert.That(
                Field<string>(receiver, "avatarArbiterOwnerToken"),
                Is.EqualTo(new string('B', 43)));
            Assert.That(
                Field<long>(receiver, "avatarArbiterRendererGeneration"),
                Is.EqualTo(2L));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
        }
    }

    [Test]
    public void StartAppliesNeutralExpressionBeforeNativeReady()
    {
        using var fixture = AvatarFixture.Create(
            "A",
            "Blink",
            "Blink1_L",
            "Blink1_R",
            "Lower_Eyelid1_L",
            "Lower_Eyelid1_R");
        Component receiver = fixture.AddReceiver();
        fixture.SetWeight("A", 70f);
        fixture.SetWeight("Blink1_L", 85f);
        fixture.SetWeight("Blink1_R", 25f);
        fixture.SetWeight("Lower_Eyelid1_L", 45f);
        fixture.SetWeight("Lower_Eyelid1_R", 10f);

        InvokeStart(receiver);

        Assert.That(fixture.Weight("A"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Blink"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Blink1_L"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Blink1_R"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Lower_Eyelid1_L"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Lower_Eyelid1_R"), Is.LessThan(1f));
    }

    [Test]
    public void AutomaticBlinkClosesAndReopensBlinkBlendShape()
    {
        using var fixture = AvatarFixture.Create("Blink", "Blink1_L", "Blink1_R");
        Component receiver = fixture.AddReceiver();

        SetField(receiver, "nextBlinkAt", 10f);
        SetField(receiver, "blinkStartedAt", -1f);
        SetField(receiver, "blinkDurationSeconds", 0.16f);
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10f);
        Assert.That(fixture.Weight("Blink"), Is.EqualTo(0f));
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.028f);
        Assert.That(fixture.Weight("Blink"), Is.EqualTo(50f).Within(0.1f));
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.056f);
        Assert.That(fixture.Weight("Blink"), Is.GreaterThan(99f));
        Assert.That(fixture.Weight("Blink1_L"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("Blink1_R"), Is.EqualTo(0f));
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.108f);
        Assert.That(fixture.Weight("Blink"), Is.EqualTo(50f).Within(0.1f));
        InvokeReceiverPrivate(receiver, "UpdateAutoBlinkAt", 10.161f);

        Assert.That(fixture.Weight("Blink"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Blink1_L"), Is.LessThan(1f));
        Assert.That(fixture.Weight("Blink1_R"), Is.LessThan(1f));
        Assert.That(Field<float>(receiver, "nextBlinkAt"), Is.GreaterThan(10.161f));
    }

    [Test]
    public void PlayPrimitiveCommandAppliesProceduralBoneMotion()
    {
        using var fixture = AvatarFixture.Create();
        Transform upperArm = fixture.AddBone("upperarm_R");
        Component receiver = fixture.AddReceiver();
        Assert.That(Field<Animator>(receiver, "animator"), Is.Null,
            "This fixture intentionally exercises the no-controller procedural fallback.");

        InvokeCommand(
            receiver,
            "playPrimitive",
            "{\"type\":\"wave\",\"options\":{\"durationMs\":1000,\"amplitude\":1.0}}");

        Assert.That(
            Quaternion.Angle(Quaternion.identity, upperArm.localRotation),
            Is.GreaterThan(10f));
    }

    [TestCase("think", "annie_think")]
    [TestCase("nod", "agree_234")]
    [TestCase("cheer", "annie_excited_bounce")]
    [TestCase("wave", "annie_wave")]
    [TestCase("shrug", "annie_shrug")]
    [TestCase("shy", "shy")]
    public void PrimitiveAliasesSelectReviewedClipsWithoutProceduralOffsets(
        string primitive, string clipId)
    {
        using var fixture = AvatarFixture.Create();
        Animator animator = AddDefaultVrmAnimator(fixture, withController: true);
        Component receiver = fixture.AddReceiver();
        var before = animator.GetComponentsInChildren<Transform>(true)
            .ToDictionary(bone => bone, bone => bone.localRotation);

        InvokeCommand(receiver, "playPrimitive", "{\"type\":\"" + primitive + "\"}");

        foreach (var bone in before)
        {
            Assert.That(Quaternion.Angle(bone.Value, bone.Key.localRotation), Is.LessThan(0.05f),
                "Selecting an authored clip must not also apply procedural offsets: " + bone.Key.name);
        }
        animator.Update(0.5f);
        bool imported = clipId.StartsWith("annie_", StringComparison.Ordinal);
        AnimationClip expectedClip = AssetDatabase.LoadAssetAtPath<AnimationClip>(
            "Assets/MaasoAvatar/Animations/Humanoid/" +
            (imported ? "OpenAnnie/" : "Actions/") + clipId + ".anim");
        Assert.That(expectedClip, Is.Not.Null);
        object anniePlayback = Field<object>(receiver, "annieMotion");
        object activeImportedId = anniePlayback.GetType().GetProperty("ActiveId").GetValue(anniePlayback);
        if (imported)
        {
            Assert.That(activeImportedId, Is.EqualTo(clipId),
                "Semantic primitives must select the integrated motion pack before legacy clips.");
        }
        else
        {
            Assert.That(activeImportedId, Is.Null,
                "Unmapped primitives must preserve their reviewed legacy clip path.");
        }
        AnimatorClipInfo[] playing = animator.IsInTransition(0)
            ? animator.GetNextAnimatorClipInfo(0)
            : animator.GetCurrentAnimatorClipInfo(0);
        Assert.That(playing.Any(info => info.clip == expectedClip), Is.True,
            primitive + " must play the real reviewed " + clipId + " asset.");
    }

    [TestCase("wave", HumanBodyBones.RightUpperArm)]
    [TestCase("cheer", HumanBodyBones.LeftUpperArm)]
    [TestCase("think", HumanBodyBones.RightLowerArm)]
    [TestCase("point_small", HumanBodyBones.RightHand)]
    [TestCase("look_away", HumanBodyBones.LeftUpperArm)]
    [TestCase("shrug", HumanBodyBones.LeftShoulder)]
    public void PrimitiveFallbackUsesDefaultVrmHumanoidBonesWithoutTouchingFingers(
        string primitive, HumanBodyBones expectedBone)
    {
        using var fixture = AvatarFixture.Create();
        Animator animator = AddDefaultVrmAnimator(fixture, withController: false);
        Component receiver = fixture.AddReceiver();
        Assert.That(animator.runtimeAnimatorController, Is.Null,
            "A missing controller must keep the mapped-bone procedural fallback reachable.");
        Transform bodyBone = animator.GetBoneTransform(expectedBone);
        Quaternion beforeBody = bodyBone.localRotation;
        string[] fingerNames = { "Thumb", "Index", "Middle", "Ring", "Little" };
        var fingers = Enum.GetValues(typeof(HumanBodyBones)).Cast<HumanBodyBones>()
            .Where(bone => fingerNames.Any(name => bone.ToString().Contains(name)))
            .Select(animator.GetBoneTransform)
            .Where(bone => bone != null)
            .ToDictionary(bone => bone, bone => bone.localRotation);
        Assert.That(fingers.Count, Is.EqualTo(30));

        InvokeCommand(receiver, "playPrimitive", "{\"type\":\"" + primitive + "\"}");

        Assert.That(Quaternion.Angle(beforeBody, bodyBone.localRotation), Is.GreaterThan(5f),
            "Fallback must use the default VRM's mapped Humanoid bone, regardless of its name.");
        foreach (var finger in fingers)
        {
            Assert.That(Quaternion.Angle(finger.Value, finger.Key.localRotation), Is.LessThan(0.05f),
                "Body fallback must preserve authored finger joints: " + finger.Key.name);
        }
    }

    [TestCase("think", 9f)]
    [TestCase("nod", 8f)]
    [TestCase("unreviewed_gesture", 3f)]
    public void PrimitiveMissingClipKeepsProceduralFallback(string primitive, float pitch)
    {
        using var fixture = AvatarFixture.Create();
        Transform head = fixture.AddBone("head");
        Component receiver = fixture.AddReceiver();
        Assert.That(Field<Animator>(receiver, "animator"), Is.Null,
            "No authored controller is available in this explicit fallback fixture.");
        InvokeCommand(receiver, "playPrimitive",
            "{\"type\":\"" + primitive + "\",\"options\":{\"amplitude\":1}}");
        Assert.That(Quaternion.Angle(Quaternion.Euler(pitch, 0f, 0f), head.localRotation),
            Is.LessThan(0.01f));
    }

    [Test]
    public void LookAwayDoesNotSelectShyAnimation()
    {
        using var fixture = AvatarFixture.Create();
        Animator animator = AddDefaultVrmAnimator(fixture, withController: true);
        Component receiver = fixture.AddReceiver();
        InvokeCommand(receiver, "playPrimitive", "{\"type\":\"look_away\"}");
        animator.Update(0.5f);
        AnimatorClipInfo[] playing = animator.GetCurrentAnimatorClipInfo(0)
            .Concat(animator.GetNextAnimatorClipInfo(0)).ToArray();
        Assert.That(playing.Any(info => info.clip.name == "shy"), Is.False,
            "Looking away must not silently become the long shy full-body animation.");
    }

    [TestCase("playPrimitive", 2400)]
    [TestCase("playMotion", 2400)]
    [TestCase("playPrimitive", 0)]
    [TestCase("playMotion", 0)]
    public void PrimitiveAndMotionHonorDurationWithoutResettingFaceOrHands(
        string method, int durationMs)
    {
        using var fixture = AvatarFixture.Create("Fun", "I");
        fixture.AddBone("head");
        Transform hand = fixture.AddBone("hand_R");
        Transform finger = fixture.AddBone("index_01_R", hand);
        hand.localRotation = Quaternion.Euler(10f, 20f, 30f);
        finger.localRotation = Quaternion.Euler(0f, 0f, 35f);
        Quaternion handPose = hand.localRotation;
        Quaternion fingerPose = finger.localRotation;
        string controllerPath = AssetDatabase.GenerateUniqueAssetPath(
            "Assets/Tests/EditMode/TempActionDuration.controller");
        string clipPath = controllerPath.Replace(".controller", ".anim");
        AnimatorController controller = CreateIdleController(controllerPath);
        try
        {
            Animator animator = fixture.Root.gameObject.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            Component receiver = fixture.AddReceiver();
            SetField(receiver, "designedIdleStateName", "idle");
            InvokeCommand(receiver, "setExpression", "{\"happy\":0.6,\"eyeOpen\":1}");
            CompleteExpressionTransition(receiver);
            InvokeCommand(receiver, "startVisemeTimeline", SingleVisemeTimeline("ih"));
            float mouthWeight = fixture.Weight("I");
            float startedAt = Time.realtimeSinceStartup;
            string options = durationMs > 0
                ? $",\"options\":{{\"durationMs\":{durationMs}}}"
                : string.Empty;
            InvokeCommand(receiver, method, "{\"type\":\"nod\"" + options + "}");
            float holdUntil = Field<float>(receiver, "actionPoseHoldUntil");
            float expectedSeconds = durationMs > 0 ? durationMs / 1000f : 1.2f;
            Assert.That(holdUntil - startedAt, Is.EqualTo(expectedSeconds).Within(0.1f));

            // Advance the deadline relative to the clock without sleeping the Editor.
            SetField(receiver, "actionPoseHoldUntil", holdUntil - 1.3f);
            InvokeReceiverPrivate(receiver, "UpdateIdlePose");
            Assert.That(Field<bool>(receiver, "designedIdleActive"), Is.EqualTo(durationMs == 0),
                "A requested 2.4s action must not return to idle at the old 1.2s deadline.");
            Assert.That(fixture.Weight("Fun"), Is.EqualTo(60f).Within(0.01f));
            Assert.That(fixture.Weight("I"), Is.EqualTo(mouthWeight).Within(0.01f));
            Assert.That(Field<bool>(receiver, "lipSyncActive"), Is.True);
            Assert.That(Quaternion.Angle(handPose, hand.localRotation), Is.LessThan(0.01f));
            Assert.That(Quaternion.Angle(fingerPose, finger.localRotation), Is.LessThan(0.01f));

            SetField(receiver, "actionPoseHoldUntil", Time.realtimeSinceStartup - 0.01f);
            InvokeReceiverPrivate(receiver, "UpdateIdlePose");
            Assert.That(Field<bool>(receiver, "designedIdleActive"), Is.True);
        }
        finally
        {
            AssetDatabase.DeleteAsset(controllerPath);
            AssetDatabase.DeleteAsset(clipPath);
        }
    }

    [Test]
    public void SetViewportSafeAreaCommandUpdatesFrontFullBodyCamera()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        using var fixture = AvatarFixture.Create();
        var cameraObject = new GameObject("Main Camera");

        try
        {
            cameraObject.tag = "MainCamera";
            cameraObject.AddComponent<Camera>();
            Type framingType = Type.GetType(FrontFullBodyCameraTypeName);
            Assert.That(framingType, Is.Not.Null, "Front full-body camera component should exist.");
            Component framing = cameraObject.AddComponent(framingType);
            SetField(framing, "targetRoot", fixture.Root);
            Component receiver = fixture.AddReceiver();

            InvokeCommand(
                receiver,
                "setViewportSafeArea",
                "{\"topSafeViewport\":0.18,\"bottomSafeViewport\":0.31}");

            Assert.That(Field<float>(framing, "topSafeViewport"), Is.EqualTo(0.18f).Within(0.001f));
            Assert.That(Field<float>(framing, "bottomSafeViewport"), Is.EqualTo(0.31f).Within(0.001f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
        }
    }

    [Test]
    public void ReviewedRemoteAvatarDescriptorRequiresHttpsHashAndPrefabName()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Unity avatar command receiver should exist.");
        MethodInfo validator = componentType.GetMethod(
            "IsApprovedRemoteAvatarDescriptor",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(validator, Is.Not.Null, "Remote avatar descriptor validation should exist.");

        string hash = new string('a', 64);
        Assert.That(
            validator.Invoke(null, new object[] { "https://cdn.example.com/creator.bundle", hash, "Creator", false }),
            Is.EqualTo(true));
        Assert.That(
            validator.Invoke(null, new object[] { "http://cdn.example.com/creator.bundle", hash, "Creator", false }),
            Is.EqualTo(false));
        Assert.That(
            validator.Invoke(null, new object[] { "https://cdn.example.com/creator.bundle", "not-a-hash", "Creator", false }),
            Is.EqualTo(false));
        Assert.That(
            validator.Invoke(null, new object[] { "https://cdn.example.com/creator.bundle", hash, "", false }),
            Is.EqualTo(false));
        Assert.That(
            validator.Invoke(null, new object[] { "https://cdn.example.com/creator.vrm", hash, "", true }),
            Is.EqualTo(true));
    }

    [Test]
    public void ReviewedAvatarCacheValidatesSizeAndSha256()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null);
        MethodInfo validator = componentType.GetMethod(
            "IsValidAvatarBundleFile",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(validator, Is.Not.Null);
        string path = Path.GetTempFileName();
        byte[] bytes = { 1, 3, 3, 7, 9 };
        File.WriteAllBytes(path, bytes);
        string sha;
        using (SHA256 algorithm = SHA256.Create())
        {
            sha = BitConverter
                .ToString(algorithm.ComputeHash(bytes))
                .Replace("-", string.Empty)
                .ToLowerInvariant();
        }

        try
        {
            object[] validArguments = { path, (long)bytes.Length, sha, null };
            Assert.That(validator.Invoke(null, validArguments), Is.EqualTo(true));
            Assert.That(validArguments[3], Is.EqualTo(string.Empty));

            object[] sizeArguments = { path, (long)bytes.Length + 1L, sha, null };
            Assert.That(validator.Invoke(null, sizeArguments), Is.EqualTo(false));
            Assert.That(sizeArguments[3], Is.EqualTo("size_mismatch"));

            object[] hashArguments =
            {
                path,
                (long)bytes.Length,
                new string('a', 64),
                null,
            };
            Assert.That(validator.Invoke(null, hashArguments), Is.EqualTo(false));
            Assert.That(hashArguments[3], Is.EqualTo("checksum_mismatch"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Test]
    public void ActiveAvatarCanBeLeasedAndRestoredWithoutCloning()
    {
        using var fixture = AvatarLeaseFixture.Create();
        Transform original = fixture.ActiveAvatarRoot;

        Assert.That(
            fixture.InvokeReceiver("TryLeaseActiveAvatarForWorld", fixture.WorldOwner),
            Is.EqualTo(true));
        Assert.That(fixture.ActiveAvatarRoot, Is.SameAs(original));
        Assert.That(original.parent, Is.SameAs(fixture.WorldOwner));
        Assert.That(fixture.ReceiverProperty<bool>("IsAvatarLeasedToWorld"), Is.True);
        Assert.That(fixture.WorldOwner.childCount, Is.EqualTo(1));

        Assert.That(
            fixture.InvokeReceiver("TryLeaseActiveAvatarForWorld", fixture.WorldOwner),
            Is.EqualTo(true));
        Assert.That(fixture.WorldOwner.childCount, Is.EqualTo(1));

        fixture.InvokeReceiver("RestoreActiveAvatarFromWorld", fixture.HomeAnchor);

        Assert.That(fixture.ActiveAvatarRoot, Is.SameAs(original));
        Assert.That(original.parent, Is.SameAs(fixture.OriginalParent));
        Assert.That(fixture.ReceiverProperty<bool>("IsAvatarLeasedToWorld"), Is.False);
        Assert.That(
            original.GetComponent<Renderer>().bounds.min.y,
            Is.EqualTo(-0.008f).Within(0.001f));
        Assert.That(original.position.x, Is.EqualTo(fixture.HomeAnchor.position.x).Within(0.001f));
        Assert.That(original.position.z, Is.EqualTo(fixture.HomeAnchor.position.z).Within(0.001f));
    }

    [Test]
    public void WorldLeaseSuppressesRootMotionAndRestoresTheStableVisualPose()
    {
        using var fixture = AvatarLeaseFixture.Create();
        Transform avatar = fixture.ActiveAvatarRoot;
        Animator animator = avatar.gameObject.AddComponent<Animator>();
        animator.applyRootMotion = true;

        Assert.That(
            fixture.InvokeReceiver("TryLeaseActiveAvatarForWorld", fixture.WorldOwner),
            Is.EqualTo(true));
        fixture.InvokeReceiver("RebaseActiveAvatarRootPose");
        Vector3 expectedPosition = avatar.localPosition;
        Quaternion expectedRotation = avatar.localRotation;
        Vector3 expectedScale = avatar.localScale;
        Assert.That(animator.applyRootMotion, Is.False);

        avatar.localPosition += new Vector3(1f, 0.5f, -0.25f);
        avatar.localRotation *= Quaternion.Euler(0f, 180f, 0f);
        avatar.localScale *= 1.4f;
        InvokeLateUpdate(fixture.Receiver);

        Assert.That(avatar.localPosition, Is.EqualTo(expectedPosition));
        Assert.That(
            Quaternion.Angle(avatar.localRotation, expectedRotation),
            Is.LessThan(0.01f));
        Assert.That(avatar.localScale, Is.EqualTo(expectedScale));

        fixture.InvokeReceiver("RestoreActiveAvatarFromWorld", fixture.HomeAnchor);
        Assert.That(animator.applyRootMotion, Is.True);
    }

    [Test]
    public void WorldOwnerLeaseMovesSameAvatarAndReturnsItHome()
    {
        using var fixture = AvatarLeaseFixture.Create();
        Type leaseType = Type.GetType(
            "Maaso.World.WorldOwnerAvatarLease, Assembly-CSharp");
        Assert.That(leaseType, Is.Not.Null, "WorldOwnerAvatarLease should exist.");
        Component lease = fixture.WorldOwner.gameObject.AddComponent(leaseType);
        Vector3 worldTarget = new(4f, 0f, -3f);
        Quaternion worldRotation = Quaternion.Euler(0f, 75f, 0f);

        Assert.That(
            InvokePublic(
                lease,
                "Bind",
                fixture.Receiver,
                fixture.HomeAnchor,
                worldTarget,
                worldRotation),
            Is.EqualTo(true));
        Assert.That(fixture.ActiveAvatarRoot.parent, Is.SameAs(fixture.WorldOwner));
        Assert.That(fixture.WorldOwner.position, Is.EqualTo(worldTarget));

        InvokePublic(lease, "CompleteReturnToHome");

        Assert.That(fixture.ActiveAvatarRoot.parent, Is.SameAs(fixture.OriginalParent));
        Assert.That(
            fixture.ActiveAvatarRoot.GetComponent<Renderer>().bounds.min.y,
            Is.EqualTo(-0.008f).Within(0.001f));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void WorldOwnerVisibilityNeverReactivatesReplacedBundledAvatar(
        bool repeatHiddenBeforeReveal)
    {
        var replacement = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        replacement.name = "ReplacementAvatar";
        try
        {
            using var fixture = AvatarLeaseFixture.Create();
            Type leaseType = Type.GetType(
                "Maaso.World.WorldOwnerAvatarLease, Assembly-CSharp");
            Assert.That(leaseType, Is.Not.Null);
            Component lease = fixture.WorldOwner.gameObject.AddComponent(leaseType);
            Assert.That(InvokePublic(lease, "Bind", fixture.Receiver,
                fixture.HomeAnchor, Vector3.zero, Quaternion.identity), Is.True);
            Transform bundledAvatar = fixture.ActiveAvatarRoot;
            InvokeCommand(fixture.Receiver, "setLocalAvatarVisible", "{\"visible\":true}");
            Assert.That(bundledAvatar.gameObject.activeSelf, Is.True);

            InvokePublic(lease, "SetWorldVisible", false);
            Assert.That(bundledAvatar.gameObject.activeSelf, Is.False);
            InvokeReceiverPrivate(fixture.Receiver, "ActivateLoadedAvatarReplacement",
                replacement, null, null, bundledAvatar, "test replacement");
            Assert.That(fixture.ActiveAvatarRoot, Is.SameAs(replacement.transform));
            Assert.That(bundledAvatar.gameObject.activeSelf, Is.False);
            Assert.That(replacement.activeSelf, Is.False,
                "The replacement must inherit the hidden world lease before the next frame.");

            if (repeatHiddenBeforeReveal)
            {
                InvokePublic(lease, "SetWorldVisible", false);
                Assert.That(bundledAvatar.gameObject.activeSelf, Is.False,
                    "Repeated hiding must not restore the retired female root.");
                Assert.That(replacement.activeSelf, Is.False);
            }

            InvokePublic(lease, "SetWorldVisible", true);
            Assert.That(bundledAvatar.gameObject.activeSelf, Is.False,
                "Showing the replacement must never reactivate the retired root.");
            Assert.That(replacement.activeSelf, Is.True);
        }
        finally
        {
            if (replacement != null)
            {
                UnityEngine.Object.DestroyImmediate(replacement);
            }
        }
    }

    [Test]
    public void WorldGroundingSurvivesResetMotionForCenterPivotAvatar()
    {
        var receiverHost = new GameObject("GroundedReceiverHost");
        var originalParent = new GameObject("GroundedOriginalParent");
        var worldOwner = new GameObject("GroundedWorldOwner");
        var homeAnchor = new GameObject("GroundedHomeAnchor");
        GameObject avatar = GameObject.CreatePrimitive(PrimitiveType.Cube);
        avatar.name = "CenterPivotAvatar";
        avatar.transform.SetParent(originalParent.transform, false);
        try
        {
            Type receiverType = Type.GetType(ComponentTypeName);
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatar.transform);
            SetField(receiver, "bundledAvatarRoot", avatar.transform);
            _ = receiverType.GetProperty("ActiveAvatarRoot")?.GetValue(receiver);

            Type groundingType = Type.GetType(
                "Maaso.World.WorldAvatarGrounding, Assembly-CSharp");
            Assert.That(groundingType, Is.Not.Null);
            MethodInfo ground = groundingType.GetMethod(
                "TryGround",
                BindingFlags.Public | BindingFlags.Static);
            Assert.That(ground, Is.Not.Null);
            object[] homeGroundingArguments = { avatar.transform, 0f, 0f };
            Assert.That(
                ground.Invoke(null, homeGroundingArguments),
                Is.EqualTo(true));

            Type leaseType = Type.GetType(
                "Maaso.World.WorldOwnerAvatarLease, Assembly-CSharp");
            Assert.That(leaseType, Is.Not.Null);
            Component lease = worldOwner.AddComponent(leaseType);
            Assert.That(
                InvokePublic(
                    lease,
                    "Bind",
                    receiver,
                    homeAnchor.transform,
                    Vector3.zero,
                    Quaternion.identity),
                Is.EqualTo(true));
            Assert.That(
                avatar.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(-0.008f).Within(0.001f));

            InvokeCommand(receiver, "playMotion", "{\"type\":\"reset\"}");

            Assert.That(
                avatar.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(-0.008f).Within(0.001f),
                "World grounding must become the motion baseline instead of resetting the avatar below the map.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(worldOwner);
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(homeAnchor);
            UnityEngine.Object.DestroyImmediate(originalParent);
            if (avatar != null)
            {
                UnityEngine.Object.DestroyImmediate(avatar);
            }
        }
    }

    [Test]
    public void ReplacingAvatarUpdatesHomeFramingTarget()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        using var fixture = AvatarFixture.Create();
        var replacement = new GameObject("ReviewedAvatar");
        var cameraObject = new GameObject("Main Camera");
        try
        {
            cameraObject.tag = "MainCamera";
            cameraObject.AddComponent<Camera>();
            Type framingType = Type.GetType(FrontFullBodyCameraTypeName);
            Assert.That(framingType, Is.Not.Null);
            Component framing = cameraObject.AddComponent(framingType);
            framingType.GetProperty("TargetRoot")?.SetValue(
                framing,
                fixture.Root);
            Component receiver = fixture.AddReceiver();

            MethodInfo bind = receiver.GetType().GetMethod(
                "BindAvatarRoot",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(bind, Is.Not.Null);
            bind.Invoke(receiver, new object[] { replacement.transform });

            Assert.That(
                framingType.GetProperty("TargetRoot")?.GetValue(framing),
                Is.SameAs(replacement.transform));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(replacement);
        }
    }

    [Test]
    public void BindingAvatarKeepsRuntimeSkinnedMeshesVisibleAfterRelocation()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        using var fixture = AvatarFixture.Create();
        var replacement = new GameObject("RelocatableAvatar");
        var head = new GameObject("HeadRenderer");
        head.transform.SetParent(replacement.transform, false);
        SkinnedMeshRenderer renderer = head.AddComponent<SkinnedMeshRenderer>();
        renderer.updateWhenOffscreen = false;

        try
        {
            Component receiver = fixture.AddReceiver();
            MethodInfo bind = receiver.GetType().GetMethod(
                "BindAvatarRoot",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(bind, Is.Not.Null);
            bind.Invoke(receiver, new object[] { replacement.transform });

            Assert.That(renderer.updateWhenOffscreen, Is.True,
                "Runtime relocation must not let a separately skinned head be culled from the Home camera.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(replacement);
        }
    }

    [Test]
    public void InitialAvatarKeepsRuntimeSkinnedMeshesVisibleAfterRelocation()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        using var fixture = AvatarFixture.Create();
        SkinnedMeshRenderer renderer =
            fixture.Root.GetComponentInChildren<SkinnedMeshRenderer>();
        Assert.That(renderer, Is.Not.Null);
        renderer.updateWhenOffscreen = false;

        Component receiver = fixture.AddReceiver();
        MethodInfo awake = receiver.GetType().GetMethod(
            "Awake",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(awake, Is.Not.Null);
        awake.Invoke(receiver, Array.Empty<object>());

        Assert.That(renderer.updateWhenOffscreen, Is.True,
            "The bundled Home avatar can be grounded and reparented without culling its head meshes.");
    }

    [Test]
    public void IdleUsesAnimatorIdleState()
    {
        using var fixture = AvatarFixture.Create();
        Transform upperArm = fixture.AddBone("upperarm_R");
        string controllerPath = AssetDatabase.GenerateUniqueAssetPath("Assets/Tests/EditMode/TempIdle.controller");
        string clipPath = controllerPath.Replace(".controller", ".anim");
        AnimatorController controller = CreateIdleController(controllerPath);

        try
        {
            Assert.That(
                controller.layers[0].stateMachine.states.Select(state => state.state.name),
                Does.Contain("idle"));
            Animator animator = fixture.Root.gameObject.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            Component receiver = fixture.AddReceiver();
            SetField(receiver, "designedIdleStateName", "idle");

            MethodInfo designedIdle = receiver.GetType().GetMethod(
                "TryStartDesignedIdle",
                BindingFlags.NonPublic | BindingFlags.Instance,
                null,
                Type.EmptyTypes,
                null);
            Assert.That(designedIdle, Is.Not.Null);
            Assert.That(designedIdle.Invoke(receiver, Array.Empty<object>()), Is.EqualTo(true));

            InvokeUpdateIdlePose(receiver);

            Assert.That(
                Quaternion.Angle(Quaternion.identity, upperArm.localRotation),
                Is.LessThan(0.01f),
                "Animator-backed idle should be the only runtime default pose source.");
        }
        finally
        {
            AssetDatabase.DeleteAsset(controllerPath);
            AssetDatabase.DeleteAsset(clipPath);
        }
    }

    [TestCase(1)]
    [TestCase(3)]
    public void DesignedIdleAvoidsCurrentAndTwoRecentVariantsAndResetsItsHistory(int variantCount)
    {
        using var fixture=AvatarFixture.Create();
        string path=AssetDatabase.GenerateUniqueAssetPath("Assets/Tests/EditMode/TempIdleHistory.controller");
        var controller=CreateIdleController(path);
        try
        {
            string[] variants=Enumerable.Range(0,variantCount).Select(i=>"idle_variant_"+i).ToArray();
            var motion=controller.layers[0].stateMachine.states[0].state.motion;
            foreach(string variant in variants)controller.layers[0].stateMachine.AddState(variant).motion=motion;
            AssetDatabase.SaveAssets();
            var animator=fixture.Root.gameObject.AddComponent<Animator>();animator.runtimeAnimatorController=controller;
            var receiver=fixture.AddReceiver();SetField(receiver,"designedIdleStateName","idle");SetField(receiver,"idleVariantStateNames",variants);SetField(receiver,"mainIdleProbability",0f);
            var start=receiver.GetType().GetMethod("TryStartDesignedIdle",BindingFlags.NonPublic|BindingFlags.Instance,null,Type.EmptyTypes,null);
            var selected=new System.Collections.Generic.List<string>();
            for(int i=0;i<9;i++)
            {
                Assert.That(start.Invoke(receiver,Array.Empty<object>()),Is.EqualTo(true));
                string next=Field<string>(receiver,"activeDesignedIdleStateName");
                if(next!="idle")Assert.That(selected.Skip(Math.Max(0,selected.Count-2)),Does.Not.Contain(next));
                selected.Add(next);
            }
            Assert.That(selected.Any(x=>x!="idle"),Is.True);
            if(variantCount==1)Assert.That(selected,Does.Contain("idle"),"The authored main idle is the safe rest when variants are exhausted.");
            receiver.GetType().GetMethod("CancelLoginDoorway",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(receiver,new object[]{"scene_reset"});
            Assert.That(((System.Collections.ICollection)Field<object>(receiver,"recentDesignedIdleStates")).Count,Is.Zero);
        }
        finally{AssetDatabase.DeleteAsset(path);AssetDatabase.DeleteAsset(path.Replace(".controller",".anim"));}
    }

    [Test]
    public void WorldLocomotionCanEnterAndLeaveWalkingState()
    {
        using var fixture = AvatarFixture.Create();
        string controllerPath = AssetDatabase.GenerateUniqueAssetPath(
            "Assets/Tests/EditMode/TempWorldLocomotion.controller");
        string idleClipPath = controllerPath.Replace(".controller", ".anim");
        string walkClipPath = controllerPath.Replace(
            ".controller",
            ".walk.anim");
        AnimatorController controller = CreateIdleController(controllerPath);

        try
        {
            AddControllerState(controller, "standard_walk", walkClipPath);
            Animator animator = fixture.Root.gameObject.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            Component receiver = fixture.AddReceiver();

            InvokePublic(receiver, "SetWorldLocomotion", true);
            Assert.That(
                receiver.GetType().GetProperty("IsWorldLocomotionActive")
                    ?.GetValue(receiver),
                Is.EqualTo(true));

            InvokePublic(receiver, "SetWorldLocomotion", false);
            Assert.That(
                receiver.GetType().GetProperty("IsWorldLocomotionActive")
                    ?.GetValue(receiver),
                Is.EqualTo(false));
        }
        finally
        {
            AssetDatabase.DeleteAsset(controllerPath);
            AssetDatabase.DeleteAsset(idleClipPath);
            AssetDatabase.DeleteAsset(walkClipPath);
        }
    }

    [Test]
    public void PlayAnimationClipHoldsVariantBeforeReturningToMainIdle()
    {
        using var fixture = AvatarFixture.Create();
        string controllerPath = AssetDatabase.GenerateUniqueAssetPath("Assets/Tests/EditMode/TempIdleVariant.controller");
        string idleClipPath = controllerPath.Replace(".controller", ".anim");
        string variantClipPath = controllerPath.Replace(".controller", ".variant.anim");
        AnimatorController controller = CreateIdleController(controllerPath);

        try
        {
            var variantClip = new AnimationClip
            {
                name = "idle_shrug",
                wrapMode = WrapMode.Loop,
            };
            AssetDatabase.CreateAsset(variantClip, variantClipPath);
            AnimatorState variantState = controller.layers[0].stateMachine.AddState("idle_shrug");
            variantState.motion = variantClip;
            AssetDatabase.SaveAssets();

            Animator animator = fixture.Root.gameObject.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            Component receiver = fixture.AddReceiver();
            float before = Time.realtimeSinceStartup;

            InvokeCommand(
                receiver,
                "playAnimationClip",
                "{\"id\":\"idle_shrug\",\"options\":{\"durationMs\":2400}}");

            Assert.That(
                Field<float>(receiver, "actionPoseHoldUntil"),
                Is.GreaterThan(before + 2.0f));
        }
        finally
        {
            AssetDatabase.DeleteAsset(controllerPath);
            AssetDatabase.DeleteAsset(idleClipPath);
            AssetDatabase.DeleteAsset(variantClipPath);
        }
    }

    [Test]
    public void SetBodyPoseWithDurationInterpolatesInsteadOfJumping()
    {
        using var fixture = AvatarFixture.Create();
        Component receiver = fixture.AddReceiver();

        InvokeCommand(receiver, "setBodyPose", "{\"x\":1.0,\"durationMs\":1000}");

        Assert.That(
            fixture.Root.localPosition.x,
            Is.LessThan(0.2f),
            "Timed body pose movement should start smoothly instead of jumping to the target.");

        System.Threading.Thread.Sleep(80);
        InvokeLateUpdate(receiver);

        Assert.That(fixture.Root.localPosition.x, Is.GreaterThan(0.001f));
        Assert.That(fixture.Root.localPosition.x, Is.LessThan(1f));
    }

    [Test]
    public void WeightedIdleSelectionUsesMainIdleForEightyPercent()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null);
        MethodInfo select = componentType.GetMethod(
            "SelectWeightedIdleState",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(select, Is.Not.Null);
        string[] variants = { "idle", "idle_1" };

        Assert.That(
            select.Invoke(null, new object[] { "idle_shrug", variants, 0.8f, 0.0f, 0 }),
            Is.EqualTo("idle_shrug"));
        Assert.That(
            select.Invoke(null, new object[] { "idle_shrug", variants, 0.8f, 0.799f, 1 }),
            Is.EqualTo("idle_shrug"));
        Assert.That(
            select.Invoke(null, new object[] { "idle_shrug", variants, 0.8f, 0.8f, 0 }),
            Is.EqualTo("idle"));
        Assert.That(
            select.Invoke(null, new object[] { "idle_shrug", variants, 0.8f, 0.99f, 1 }),
            Is.EqualTo("idle_1"));
    }

    [Test]
    public void ScreenTapSelectsLookAroundOrRightIdleClip()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null);
        MethodInfo select = componentType.GetMethod(
            "SelectScreenTapClipId",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(select, Is.Not.Null);

        Assert.That(select.Invoke(null, new object[] { 0.1f }), Is.EqualTo("idle_look_around_1"));
        Assert.That(select.Invoke(null, new object[] { 0.5f }), Is.EqualTo("idle_look_around_1"));
        Assert.That(select.Invoke(null, new object[] { 0.9f }), Is.EqualTo("idle_turn_right_1"));
    }

    [Test]
    public void ReactToScreenTapCommandHoldsAvatarAttention()
    {
        using var fixture = AvatarFixture.Create();
        string controllerPath = AssetDatabase.GenerateUniqueAssetPath("Assets/Tests/EditMode/TempScreenTap.controller");
        string idleClipPath = controllerPath.Replace(".controller", ".anim");
        string lookClipPath = controllerPath.Replace(".controller", ".look.anim");
        string rightClipPath = controllerPath.Replace(".controller", ".right.anim");
        AnimatorController controller = CreateIdleController(controllerPath);

        try
        {
            AddControllerState(controller, "idle_look_around_1", lookClipPath);
            AddControllerState(controller, "idle_turn_right_1", rightClipPath);
            Animator animator = fixture.Root.gameObject.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            Component receiver = fixture.AddReceiver();
            float before = Time.realtimeSinceStartup;

            InvokeCommand(
                receiver,
                "reactToScreenTap",
                "{\"x\":0.9,\"y\":0.5,\"durationMs\":1800}");

            Assert.That(
                Field<float>(receiver, "actionPoseHoldUntil"),
                Is.GreaterThan(before + 1.5f));
        }
        finally
        {
            AssetDatabase.DeleteAsset(controllerPath);
            AssetDatabase.DeleteAsset(idleClipPath);
            AssetDatabase.DeleteAsset(lookClipPath);
            AssetDatabase.DeleteAsset(rightClipPath);
        }
    }

    [Test]
    public void RuntimeDoesNotExposeProceduralIdleFallback()
    {
        Type componentType = Type.GetType(ComponentTypeName);

        Assert.That(componentType, Is.Not.Null);
        Assert.That(
            componentType.GetMethod("ApplyIdlePose", BindingFlags.NonPublic | BindingFlags.Instance),
            Is.Null);
        Assert.That(
            componentType.GetField("idleBreathingEnabled", BindingFlags.NonPublic | BindingFlags.Instance),
            Is.Null);
    }

    [Test]
    public void IdleDoesNotProcedurallyGuessWhenNoDesignedIdleExists()
    {
        using var fixture = AvatarFixture.Create();
        Transform upperArm = fixture.AddBone("upperarm_R");
        Component receiver = fixture.AddReceiver();

        InvokeUpdateIdlePose(receiver);

        Assert.That(
            Quaternion.Angle(Quaternion.identity, upperArm.localRotation),
            Is.LessThan(0.01f),
            "Runtime idle should not invent a hand-authored pose when no designed Animator/VRC idle is available.");
    }

    [TestCase("BindAvatarRoot")]
    [TestCase("ResetAvatarArbiterState")]
    [TestCase("OnDisable")]
    public void FaceOwnershipResetCancelsPendingTransitions(string resetMethod)
    {
        using var fixture = AvatarFixture.Create("Fun", "I", "Blink");
        using var replacement = AvatarFixture.Create("Fun", "I", "Blink");
        Transform oldHead = fixture.AddBone("head");
        Transform newHead = replacement.AddBone("head");
        Component receiver = fixture.AddReceiver();
        InvokeCommand(receiver, "setExpression", "{\"happy\":1,\"eyeOpen\":1}");
        InvokeCommand(receiver, "setGaze", "{\"headX\":1,\"eyeX\":1}");
        InvokeCommand(receiver, "startVisemeTimeline", SingleVisemeTimeline("ih"));
        InvokeReceiverPrivate(receiver, "UpdateExpressionTransition",
            Field<float>(receiver, "expressionTransitionStartedAt") + 0.11f);
        InvokeReceiverPrivate(receiver, "UpdateGazeTransition",
            Field<float>(receiver, "gazeTransitionStartedAt") + 0.08f);
        InvokeReceiverPrivate(receiver, "ApplyGazePose");
        Assert.That(Quaternion.Angle(Quaternion.identity, oldHead.localRotation), Is.GreaterThan(10f));

        if (resetMethod == "BindAvatarRoot")
            InvokeReceiverPrivate(receiver, resetMethod, replacement.Root);
        else
            InvokeReceiverPrivate(receiver, resetMethod);

        Assert.That(Field<bool>(receiver, "expressionTransitionActive"), Is.False);
        Assert.That(Field<bool>(receiver, "gazeTransitionActive"), Is.False);
        Assert.That(Field<bool>(receiver, "gazeActive"), Is.False);
        Assert.That(Field<bool>(receiver, "lipSyncActive"), Is.False);
        InvokeReceiverPrivate(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 10f);
        InvokeReceiverPrivate(receiver, "UpdateGazeTransition", Time.realtimeSinceStartup + 10f);
        InvokeLateUpdate(receiver);
        Assert.That(Quaternion.Angle(Quaternion.identity, oldHead.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(Quaternion.identity, newHead.localRotation), Is.LessThan(0.01f));
        Assert.That(fixture.Weight("Fun"), Is.EqualTo(0f));
        Assert.That(fixture.Weight("I"), Is.EqualTo(0f));
        Assert.That(replacement.Weight("Fun"), Is.EqualTo(0f));
        Assert.That(replacement.Weight("I"), Is.EqualTo(0f));
    }

    [Test]
    public void GazeTransitionsReturnToCenterBeforeReleasingOwnership()
    {
        using var fixture = AvatarFixture.Create();
        Transform head = fixture.AddBone("head");
        Transform eye = fixture.AddBone("eye_L", head);
        Transform rightEye = fixture.AddBone("eye_R", head);
        Component receiver = fixture.AddReceiver();
        InvokeCommand(receiver, "setGaze", "{\"headX\":1,\"eyeX\":1}");
        Assert.That(Quaternion.Angle(Quaternion.identity, head.localRotation), Is.LessThan(0.01f));
        float startedAt = Field<float>(receiver, "gazeTransitionStartedAt");
        InvokeReceiverPrivate(receiver, "UpdateGazeTransition", startedAt + 0.08f);
        InvokeReceiverPrivate(receiver, "ApplyGazePose");
        Assert.That(Quaternion.Angle(Quaternion.identity, head.localRotation), Is.EqualTo(14f).Within(0.05f));
        Assert.That(Quaternion.Angle(Quaternion.identity, eye.localRotation), Is.EqualTo(8f).Within(0.05f));
        Assert.That(Quaternion.Angle(Quaternion.identity, rightEye.localRotation), Is.EqualTo(8f).Within(0.05f));

        CompleteGazeTransition(receiver);
        InvokeReceiverPrivate(receiver, "ApplyGazePose");
        Quaternion beforeClear = head.localRotation;
        InvokeCommand(receiver, "clearGaze", "{}");
        Assert.That(Quaternion.Angle(beforeClear, head.localRotation), Is.LessThan(0.01f));
        Assert.That(Field<bool>(receiver, "gazeActive"), Is.True);
        startedAt = Field<float>(receiver, "gazeTransitionStartedAt");
        InvokeReceiverPrivate(receiver, "UpdateGazeTransition", startedAt + 0.08f);
        InvokeReceiverPrivate(receiver, "ApplyGazePose");
        Assert.That(Quaternion.Angle(Quaternion.identity, head.localRotation), Is.EqualTo(14f).Within(0.05f));
        CompleteGazeTransition(receiver);
        Assert.That(Field<bool>(receiver, "gazeActive"), Is.False);
        Assert.That(Quaternion.Angle(Quaternion.identity, head.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(Quaternion.identity, eye.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(Quaternion.identity, rightEye.localRotation), Is.LessThan(0.01f));
    }

    [Test]
    public void GazePresentationUsesTheSamePathOnMobileAndDesktop()
    {
        string source = File.ReadAllText(
            "Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs");
        foreach ((string start, string end) in new[]
        {
            ("private void LateUpdate()", "public void OnFlutterCommand("),
            ("private void ApplyGaze(", "private void ApplyGazePose()"),
        })
        {
            int startIndex = source.IndexOf(start, StringComparison.Ordinal);
            int endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
            string region = source.Substring(startIndex, endIndex - startIndex);
            Assert.That(region.Contains("#if"), Is.False,
                "Mobile must compile the same gaze transition, cleanup and eye path as desktop.");
        }
        Assert.That(source.Contains("StabilizeEyeBones"), Is.False,
            "A mobile-only bind-pose write must not erase runtime gaze.");
        Type receiverType = Type.GetType(ComponentTypeName);
        int receiverOrder = receiverType.GetCustomAttribute<DefaultExecutionOrder>().order;
        int vrmOrder = typeof(Vrm10Instance).GetCustomAttribute<DefaultExecutionOrder>().order;
        Assert.That(receiverOrder, Is.LessThan(vrmOrder));
    }

    [Test]
    public void SetGazeAppliesHeadAndEyesAndLateUpdateKeepsThePoseStable()
    {
        using var fixture = AvatarFixture.Create();
        Transform head = fixture.AddBone("head");
        Transform leftEye = fixture.AddBone("eye_L", head);
        Transform rightEye = fixture.AddBone("eye_R", head);
        head.localPosition = new Vector3(0f, 1.45f, 0.01f);
        leftEye.localPosition = new Vector3(-0.03f, 0.02f, 0.08f);
        rightEye.localPosition = new Vector3(0.03f, 0.02f, 0.08f);
        head.localRotation = Quaternion.Euler(1f, 3f, -2f);
        leftEye.localRotation = Quaternion.Euler(0f, -2f, 0f);
        rightEye.localRotation = Quaternion.Euler(0f, 2f, 0f);
        Quaternion headBaseRotation = head.localRotation;
        Quaternion leftBaseRotation = leftEye.localRotation;
        Quaternion rightBaseRotation = rightEye.localRotation;
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "setGaze",
            "{\"eyeX\":0.5,\"eyeY\":-0.4,\"headX\":0.75,\"headY\":0.6}");
        CompleteGazeTransition(receiver);
        InvokeLateUpdate(receiver);

        Quaternion expectedHead = headBaseRotation * Quaternion.Euler(-10.8f, -21f, 0f);
        Quaternion expectedLeftEye = leftBaseRotation * Quaternion.Euler(4f, -8f, 0f);
        Quaternion expectedRightEye = rightBaseRotation * Quaternion.Euler(4f, -8f, 0f);

        Assert.That(Quaternion.Angle(expectedHead, head.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(expectedLeftEye, leftEye.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(expectedRightEye, rightEye.localRotation), Is.LessThan(0.01f));

        Vector3 animatedHeadPosition =
            head.localPosition + new Vector3(0.1f, -0.2f, 0.3f);
        Vector3 animatedLeftEyePosition =
            leftEye.localPosition + new Vector3(0.2f, 0.1f, -0.05f);
        Vector3 animatedRightEyePosition =
            rightEye.localPosition + new Vector3(-0.2f, 0.1f, -0.05f);
        Quaternion animatedHeadRotation = Quaternion.Euler(-45f, 70f, 15f);
        Quaternion animatedLeftEyeRotation = Quaternion.Euler(55f, 80f, 20f);
        Quaternion animatedRightEyeRotation = Quaternion.Euler(-35f, -65f, -15f);
        head.localPosition = animatedHeadPosition;
        leftEye.localPosition = animatedLeftEyePosition;
        rightEye.localPosition = animatedRightEyePosition;
        head.localRotation = animatedHeadRotation;
        leftEye.localRotation = animatedLeftEyeRotation;
        rightEye.localRotation = animatedRightEyeRotation;

        InvokeLateUpdate(receiver);

        Assert.That(
            Vector3.Distance(animatedHeadPosition, head.localPosition),
            Is.LessThan(0.0001f));
        Assert.That(
            Vector3.Distance(animatedLeftEyePosition, leftEye.localPosition),
            Is.LessThan(0.0001f));
        Assert.That(
            Vector3.Distance(animatedRightEyePosition, rightEye.localPosition),
            Is.LessThan(0.0001f));
        Assert.That(
            Quaternion.Angle(animatedHeadRotation, head.localRotation),
            Is.GreaterThan(0.01f));
        Assert.That(
            Quaternion.Angle(animatedLeftEyeRotation, leftEye.localRotation),
            Is.GreaterThan(0.01f));
        Assert.That(
            Quaternion.Angle(animatedRightEyeRotation, rightEye.localRotation),
            Is.GreaterThan(0.01f));

        Quaternion firstHeadResult = head.localRotation;
        Quaternion firstLeftEyeResult = leftEye.localRotation;
        Quaternion firstRightEyeResult = rightEye.localRotation;

        InvokeLateUpdate(receiver);

        Assert.That(Quaternion.Angle(firstHeadResult, head.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(firstLeftEyeResult, leftEye.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(firstRightEyeResult, rightEye.localRotation), Is.LessThan(0.01f));
    }

    [Test]
    public void EyeGazeUsesHeadAxesWhenEyeParentHasARotatedRigBasis()
    {
        using var fixture = AvatarFixture.Create();
        Transform head = fixture.AddBone("head");
        Transform leftEyeParent = fixture.AddBone("eye_scale_L", head);
        Transform rightEyeParent = fixture.AddBone("eye_scale_R", head);
        leftEyeParent.localRotation = new Quaternion(
            0.000013302242f,
            0.7074984f,
            0.706715f,
            0.00001304183f);
        rightEyeParent.localRotation = leftEyeParent.localRotation;
        Transform leftEye = fixture.AddBone("eye_L", leftEyeParent);
        Transform rightEye = fixture.AddBone("eye_R", rightEyeParent);
        Quaternion leftEyeBaseWorldRotation = leftEye.rotation;
        Quaternion rightEyeBaseWorldRotation = rightEye.rotation;
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "setGaze",
            "{\"eyeX\":1,\"eyeY\":0.5,\"headX\":0,\"headY\":0}");
        CompleteGazeTransition(receiver);
        InvokeLateUpdate(receiver);

        Quaternion expectedHeadSpaceDelta = Quaternion.Euler(-5f, -16f, 0f);
        AssertEyeWorldDeltaMatchesHeadSpace(
            leftEye,
            leftEyeBaseWorldRotation,
            head,
            expectedHeadSpaceDelta);
        AssertEyeWorldDeltaMatchesHeadSpace(
            rightEye,
            rightEyeBaseWorldRotation,
            head,
            expectedHeadSpaceDelta);
    }

    private static void AssertEyeWorldDeltaMatchesHeadSpace(
        Transform eye,
        Quaternion baseWorldRotation,
        Transform head,
        Quaternion expectedHeadSpaceDelta)
    {
        Quaternion worldDelta = eye.rotation * Quaternion.Inverse(baseWorldRotation);
        Quaternion headSpaceDelta =
            Quaternion.Inverse(head.rotation) * worldDelta * head.rotation;
        Assert.That(
            Quaternion.Angle(expectedHeadSpaceDelta, headSpaceDelta),
            Is.LessThan(0.01f));
    }

    [Test]
    public void SetGazeFallsBackToDirectionalEyeBlendShapesWithoutEyeBones()
    {
        string[] gazeBlendShapes =
        {
            "eye_look_left.L",
            "eye_look_left.R",
            "eye_look_right.L",
            "eye_look_right.R",
            "eye_look_up.L",
            "eye_look_up.R",
            "eye_look_down.L",
            "eye_look_down.R",
        };
        using var fixture = AvatarFixture.Create(gazeBlendShapes);
        fixture.AddBone("head");
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "setGaze",
            "{\"eyeX\":0.75,\"eyeY\":0.4,\"headX\":0,\"headY\":0}");
        CompleteGazeTransition(receiver);
        InvokeLateUpdate(receiver);

        Assert.That(fixture.Weight("eye_look_left.L"), Is.EqualTo(75f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_left.R"), Is.EqualTo(75f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_right.L"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_right.R"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_up.L"), Is.EqualTo(40f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_up.R"), Is.EqualTo(40f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_down.L"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_down.R"), Is.EqualTo(0f).Within(0.01f));

        InvokeCommand(
            receiver,
            "setGaze",
            "{\"eyeX\":-0.5,\"eyeY\":-0.25,\"headX\":0,\"headY\":0}");
        CompleteGazeTransition(receiver);
        InvokeLateUpdate(receiver);

        Assert.That(fixture.Weight("eye_look_left.L"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_left.R"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_right.L"), Is.EqualTo(50f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_right.R"), Is.EqualTo(50f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_up.L"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_up.R"), Is.EqualTo(0f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_down.L"), Is.EqualTo(25f).Within(0.01f));
        Assert.That(fixture.Weight("eye_look_down.R"), Is.EqualTo(25f).Within(0.01f));

        InvokeCommand(receiver, "clearGaze", "{}");
        CompleteGazeTransition(receiver);

        foreach (string blendShape in gazeBlendShapes)
        {
            Assert.That(fixture.Weight(blendShape), Is.EqualTo(0f).Within(0.01f));
        }
    }

    [Test]
    public void ClearGazeRestoresHeadAndEyesToTheirLocalBindPose()
    {
        using var fixture = AvatarFixture.Create();
        Transform head = fixture.AddBone("head");
        Transform leftEye = fixture.AddBone("eye_L", head);
        Transform rightEye = fixture.AddBone("eye_R", head);
        head.localPosition = new Vector3(0f, 1.45f, 0.01f);
        leftEye.localPosition = new Vector3(-0.03f, 0.02f, 0.08f);
        rightEye.localPosition = new Vector3(0.03f, 0.02f, 0.08f);
        head.localRotation = Quaternion.Euler(1f, 3f, -2f);
        leftEye.localRotation = Quaternion.Euler(0f, -2f, 0f);
        rightEye.localRotation = Quaternion.Euler(0f, 2f, 0f);
        Vector3 headBasePosition = head.localPosition;
        Vector3 leftBasePosition = leftEye.localPosition;
        Vector3 rightBasePosition = rightEye.localPosition;
        Quaternion headBaseRotation = head.localRotation;
        Quaternion leftBaseRotation = leftEye.localRotation;
        Quaternion rightBaseRotation = rightEye.localRotation;
        Component receiver = fixture.AddReceiver();

        InvokeCommand(
            receiver,
            "setGaze",
            "{\"eyeX\":1.0,\"eyeY\":-1.0,\"headX\":1.0,\"headY\":-1.0}");
        CompleteGazeTransition(receiver);
        InvokeLateUpdate(receiver);
        InvokeCommand(receiver, "clearGaze", "{}");
        CompleteGazeTransition(receiver);

        Assert.That(Vector3.Distance(headBasePosition, head.localPosition), Is.LessThan(0.0001f));
        Assert.That(Vector3.Distance(leftBasePosition, leftEye.localPosition), Is.LessThan(0.0001f));
        Assert.That(Vector3.Distance(rightBasePosition, rightEye.localPosition), Is.LessThan(0.0001f));
        Assert.That(Quaternion.Angle(headBaseRotation, head.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(leftBaseRotation, leftEye.localRotation), Is.LessThan(0.01f));
        Assert.That(Quaternion.Angle(rightBaseRotation, rightEye.localRotation), Is.LessThan(0.01f));

        Quaternion animatedHeadRotation = Quaternion.Euler(-45f, 70f, 15f);
        Quaternion animatedLeftEyeRotation = Quaternion.Euler(55f, 80f, 20f);
        Quaternion animatedRightEyeRotation = Quaternion.Euler(-35f, -65f, -15f);
        head.localRotation = animatedHeadRotation;
        leftEye.localRotation = animatedLeftEyeRotation;
        rightEye.localRotation = animatedRightEyeRotation;
        InvokeLateUpdate(receiver);

        Assert.That(
            Quaternion.Angle(animatedHeadRotation, head.localRotation),
            Is.LessThan(0.01f),
            "Clearing gaze should release the head back to Animator and gesture ownership after centering it once.");
        Assert.That(
            Quaternion.Angle(animatedLeftEyeRotation, leftEye.localRotation),
            Is.LessThan(0.01f));
        Assert.That(
            Quaternion.Angle(animatedRightEyeRotation, rightEye.localRotation),
            Is.LessThan(0.01f));
    }











    private static string SerializeAvatarLoadResult(object capabilityProfile)
    {
        Type receiverType = Type.GetType(ComponentTypeName);
        Assert.That(receiverType, Is.Not.Null);
        MethodInfo serialize = receiverType.GetMethod(
            "SerializeAvatarLoadResult",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(serialize, Is.Not.Null);
        return (string)serialize.Invoke(
            null,
            new object[]
            {
                "request-1",
                true,
                string.Empty,
                string.Empty,
                false,
                string.Empty,
                capabilityProfile,
            });
    }

    private static void InvokeCommand(Component receiver, string method, string json)
    {
        MethodInfo onFlutterCommand = receiver.GetType().GetMethod("OnFlutterCommand");
        Assert.That(onFlutterCommand, Is.Not.Null);
        onFlutterCommand.Invoke(receiver, new object[] { Payload(method, json) });
    }

    private static void InvokeUpdateIdlePose(Component receiver)
    {
        MethodInfo updateIdlePose = receiver.GetType().GetMethod(
            "UpdateIdlePose",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(updateIdlePose, Is.Not.Null);
        updateIdlePose.Invoke(receiver, Array.Empty<object>());
    }

    private static void InvokeStart(Component receiver)
    {
        MethodInfo start = receiver.GetType().GetMethod(
            "Start",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(start, Is.Not.Null);
        start.Invoke(receiver, Array.Empty<object>());
    }

    private static void CompleteExpressionTransition(Component receiver)
    {
        InvokeReceiverPrivate(receiver, "UpdateExpressionTransition",
            Field<float>(receiver, "expressionTransitionStartedAt") + 1f);
    }

    private static void CompleteGazeTransition(Component receiver)
    {
        InvokeReceiverPrivate(receiver, "UpdateGazeTransition",
            Field<float>(receiver, "gazeTransitionStartedAt") + 1f);
    }

    private static object InvokeReceiverPrivate(
        Component receiver, string name, params object[] arguments)
    {
        MethodInfo method = receiver.GetType().GetMethod(
            name, BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(method, Is.Not.Null, name);
        return method.Invoke(receiver, arguments);
    }

    private static void InvokeUpdateAutoBlink(Component receiver)
    {
        MethodInfo updateAutoBlink = receiver.GetType().GetMethod(
            "UpdateAutoBlink",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(updateAutoBlink, Is.Not.Null);
        updateAutoBlink.Invoke(receiver, Array.Empty<object>());
    }

    private static void InvokeApplyLipSyncFrame(
        Component receiver,
        float framePosition)
    {
        MethodInfo apply = receiver.GetType().GetMethod(
            "ApplyLipSyncFrame",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(apply, Is.Not.Null);
        apply.Invoke(receiver, new object[] { framePosition });
    }

    private static void InvokeLateUpdate(Component receiver)
    {
        MethodInfo lateUpdate = receiver.GetType().GetMethod(
            "LateUpdate",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(lateUpdate, Is.Not.Null);
        lateUpdate.Invoke(receiver, Array.Empty<object>());
    }

    private static object InvokePublic(
        Component component,
        string methodName,
        params object[] arguments)
    {
        MethodInfo method = component.GetType().GetMethod(
            methodName,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(method, Is.Not.Null, methodName);
        return method.Invoke(component, arguments);
    }

    private static T Field<T>(Component component, string name)
    {
        FieldInfo field = component.GetType().GetField(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        return (T)field.GetValue(component);
    }

    private static float VisemeWeight(object weights, string name)
    {
        Assert.That(weights, Is.Not.Null);
        FieldInfo field = weights.GetType().GetField(
            name,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        return (float)field.GetValue(weights);
    }

    private static void SetField(Component component, string name, object value)
    {
        FieldInfo field = component.GetType().GetField(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        field.SetValue(component, value);
    }

    private static Animator AddDefaultVrmAnimator(AvatarFixture fixture, bool withController)
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab, Is.Not.Null);
        GameObject model = UnityEngine.Object.Instantiate(prefab, fixture.Root);
        Animator animator = model.GetComponentInChildren<Animator>(true);
        Assert.That(animator, Is.Not.Null);
        Assert.That(animator.isHuman, Is.True);
        animator.applyRootMotion = false;
        animator.runtimeAnimatorController = withController
            ? AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller")
            : null;
        if (withController)
        {
            animator.Rebind();
            animator.Update(0f);
        }
        return animator;
    }

    private static AnimatorController CreateIdleController(string path)
    {
        var clip = new AnimationClip
        {
            name = "idle",
            wrapMode = WrapMode.Loop,
        };
        AssetDatabase.CreateAsset(clip, path.Replace(".controller", ".anim"));
        var controller = AnimatorController.CreateAnimatorControllerAtPath(path);
        AnimatorState state = controller.layers[0].stateMachine.AddState("idle");
        state.motion = clip;
        controller.layers[0].stateMachine.defaultState = state;
        AssetDatabase.SaveAssets();
        return controller;
    }

    private static AnimatorState AddControllerState(
        AnimatorController controller,
        string stateName,
        string clipPath)
    {
        var clip = new AnimationClip
        {
            name = stateName,
            wrapMode = WrapMode.Loop,
        };
        AssetDatabase.CreateAsset(clip, clipPath);
        AnimatorState state = controller.layers[0].stateMachine.AddState(stateName);
        state.motion = clip;
        AssetDatabase.SaveAssets();
        return state;
    }

    private static string Payload(string method, string json)
    {
        string escaped = json.Replace("\\", "\\\\").Replace("\"", "\\\"");
        return $"{{\"method\":\"{method}\",\"json\":\"{escaped}\"}}";
    }

    private static string SingleVisemeTimeline(string viseme) =>
        "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2]," +
        $"\"cues\":[{{\"frame\":0,\"viseme\":\"{viseme}\"}}]," +
        "\"frameRate\":30}";

    private static void AssertActiveVowel(
        AvatarFixture fixture,
        string active)
    {
        foreach (string vowel in new[] { "A", "I", "U", "E", "O" })
        {
            if (vowel == active)
            {
                Assert.That(fixture.Weight(vowel), Is.GreaterThan(35f), vowel);
            }
            else
            {
                Assert.That(fixture.Weight(vowel), Is.LessThan(1f), vowel);
            }
        }
    }

    private static string ArbiterCommandJson(
        string rendererPayload,
        long ticket,
        string channel = "mouth")
    {
        string digest = Sha256Hex(rendererPayload);
        string escapedPayload = rendererPayload
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"");
        return "{" +
            "\"protocolVersion\":1," +
            "\"requestId\":\"request_1\"," +
            $"\"ticket\":{ticket}," +
            "\"rendererId\":\"renderer-instance-1\"," +
            $"\"ownerToken\":\"{new string('A', 43)}\"," +
            $"\"commitToken\":\"{new string('C', 43)}\"," +
            "\"accountGeneration\":7," +
            "\"rendererGeneration\":1," +
            $"\"channel\":\"{channel}\"," +
            "\"fingerprint\":\"0123456789abcdef\"," +
            $"\"payloadJson\":\"{escapedPayload}\"," +
            $"\"payloadSha256\":\"{digest}\"," +
            $"\"deadlineEpochMs\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000L}," +
            "\"clearsChannel\":false" +
            "}";
    }

    private static string ArbiterResetJson()
    {
        const string payload = "{\"reset\":true}";
        return "{" +
            "\"protocolVersion\":1," +
            "\"requestId\":\"reset_1\"," +
            "\"requirementId\":1," +
            "\"rendererId\":\"renderer-instance-1\"," +
            $"\"targetOwnerToken\":\"{new string('B', 43)}\"," +
            $"\"commitToken\":\"{new string('D', 43)}\"," +
            "\"retiredAccountGeneration\":7," +
            "\"retiredRendererGeneration\":1," +
            "\"targetAccountGeneration\":8," +
            "\"targetRendererGeneration\":2," +
            "\"payloadJson\":\"{\\\"reset\\\":true}\"," +
            $"\"payloadSha256\":\"{Sha256Hex(payload)}\"," +
            $"\"deadlineEpochMs\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000L}" +
            "}";
    }

    private static string Sha256Hex(string value)
    {
        using SHA256 algorithm = SHA256.Create();
        byte[] digest = algorithm.ComputeHash(System.Text.Encoding.UTF8.GetBytes(value));
        return string.Concat(digest.Select(item => item.ToString("x2")));
    }

    private static Mesh CreateBlendShapeMesh(params string[] blendShapes)
    {
        var mesh = new Mesh
        {
            vertices = new[]
            {
                new Vector3(0f, 0f, 0f),
                new Vector3(0f, 1f, 0f),
                new Vector3(1f, 0f, 0f),
            },
            triangles = new[] { 0, 1, 2 },
        };
        var deltaVertices = new[]
        {
            Vector3.zero,
            new Vector3(0f, 0.01f, 0f),
            Vector3.zero,
        };
        var deltaNormals = new Vector3[3];
        var deltaTangents = new Vector3[3];
        foreach (string blendShape in blendShapes)
        {
            mesh.AddBlendShapeFrame(
                blendShape,
                100f,
                deltaVertices,
                deltaNormals,
                deltaTangents);
        }

        return mesh;
    }

    private sealed class AvatarFixture : IDisposable
    {
        private readonly GameObject root;
        private readonly SkinnedMeshRenderer face;

        private AvatarFixture(GameObject root, SkinnedMeshRenderer face)
        {
            this.root = root;
            this.face = face;
        }

        public Transform Root => root.transform;

        public static AvatarFixture Create(params string[] blendShapes)
        {
            var root = new GameObject("AvatarRoot");
            var faceObject = new GameObject("Face");
            faceObject.transform.SetParent(root.transform, false);
            SkinnedMeshRenderer renderer = faceObject.AddComponent<SkinnedMeshRenderer>();
            renderer.sharedMesh = CreateMesh(blendShapes);
            return new AvatarFixture(root, renderer);
        }

        public Component AddReceiver()
        {
            Type componentType = Type.GetType(ComponentTypeName);
            Assert.That(componentType, Is.Not.Null, "Unity avatar command receiver should exist.");
            Component receiver = root.AddComponent(componentType);
            SetField(receiver, "avatarRoot", root.transform);
            SetField(receiver, "faceRenderer", face);
            SetField(receiver, "animator", root.GetComponentInChildren<Animator>());
            MethodInfo ensureAvatar = componentType.GetMethod(
                "EnsureAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(ensureAvatar, Is.Not.Null);
            ensureAvatar.Invoke(receiver, Array.Empty<object>());
            // Normal receiver tests represent an explicitly visible Home
            // avatar. Hidden-owner behavior has dedicated fixtures/tests.
            InvokeCommand(receiver, "setLocalAvatarVisible", "{\"visible\":true}");
            return receiver;
        }

        public Transform AddBone(string name, Transform parent = null)
        {
            var bone = new GameObject(name);
            bone.transform.SetParent(parent == null ? root.transform : parent, false);
            return bone.transform;
        }

        public float Weight(string blendShape)
        {
            Mesh mesh = face.sharedMesh;
            int index = mesh.GetBlendShapeIndex(blendShape);
            Assert.That(index, Is.GreaterThanOrEqualTo(0), blendShape);
            return face.GetBlendShapeWeight(index);
        }

        public void SetWeight(string blendShape, float weight)
        {
            Mesh mesh = face.sharedMesh;
            int index = mesh.GetBlendShapeIndex(blendShape);
            Assert.That(index, Is.GreaterThanOrEqualTo(0), blendShape);
            face.SetBlendShapeWeight(index, weight);
        }

        public void Dispose()
        {
            if (root != null)
            {
                UnityEngine.Object.DestroyImmediate(root);
            }
        }

        private static void SetField(Component receiver, string name, object value)
        {
            FieldInfo field = receiver.GetType().GetField(
                name,
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(field, Is.Not.Null, name);
            field.SetValue(receiver, value);
        }

        private static Mesh CreateMesh(params string[] blendShapes)
        {
            var mesh = new Mesh
            {
                vertices = new[]
                {
                    new Vector3(0f, 0f, 0f),
                    new Vector3(0f, 1f, 0f),
                    new Vector3(1f, 0f, 0f),
                },
                triangles = new[] { 0, 1, 2 },
            };
            var deltaVertices = new[]
            {
                Vector3.zero,
                new Vector3(0f, 0.01f, 0f),
                Vector3.zero,
            };
            var deltaNormals = new Vector3[3];
            var deltaTangents = new Vector3[3];
            foreach (string blendShape in blendShapes)
            {
                mesh.AddBlendShapeFrame(
                    blendShape,
                    100f,
                    deltaVertices,
                    deltaNormals,
                    deltaTangents);
            }

            return mesh;
        }
    }

    private sealed class AvatarLeaseFixture : IDisposable
    {
        private readonly GameObject receiverHost;
        private readonly GameObject originalParent;
        private readonly GameObject worldOwner;
        private readonly GameObject homeAnchor;
        private readonly GameObject avatar;

        private AvatarLeaseFixture(
            GameObject receiverHost,
            GameObject originalParent,
            GameObject worldOwner,
            GameObject homeAnchor,
            GameObject avatar,
            Component receiver)
        {
            this.receiverHost = receiverHost;
            this.originalParent = originalParent;
            this.worldOwner = worldOwner;
            this.homeAnchor = homeAnchor;
            this.avatar = avatar;
            Receiver = receiver;
        }

        public Component Receiver { get; }
        public Transform OriginalParent => originalParent.transform;
        public Transform WorldOwner => worldOwner.transform;
        public Transform HomeAnchor => homeAnchor.transform;
        public Transform ActiveAvatarRoot =>
            ReceiverProperty<Transform>("ActiveAvatarRoot");

        public static AvatarLeaseFixture Create()
        {
            var receiverHost = new GameObject("ReceiverHost");
            var originalParent = new GameObject("OriginalAvatarParent");
            var worldOwner = new GameObject("WorldOwner");
            var homeAnchor = new GameObject("HomeAgentAnchor");
            homeAnchor.transform.position = new Vector3(2f, 0f, -1f);
            GameObject avatar = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            avatar.name = "ActiveAvatar";
            avatar.transform.SetParent(originalParent.transform, false);
            avatar.transform.localPosition = new Vector3(0f, 1f, 0f);

            Type receiverType = Type.GetType(ComponentTypeName);
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatar.transform);
            SetField(receiver, "bundledAvatarRoot", avatar.transform);
            return new AvatarLeaseFixture(
                receiverHost,
                originalParent,
                worldOwner,
                homeAnchor,
                avatar,
                receiver);
        }

        public object InvokeReceiver(string methodName, params object[] arguments) =>
            InvokePublic(Receiver, methodName, arguments);

        public T ReceiverProperty<T>(string name)
        {
            PropertyInfo property = Receiver.GetType().GetProperty(
                name,
                BindingFlags.Public | BindingFlags.Instance);
            Assert.That(property, Is.Not.Null, name);
            return (T)property.GetValue(Receiver);
        }

        public void Dispose()
        {
            PropertyInfo leasedProperty = Receiver?.GetType().GetProperty(
                "IsAvatarLeasedToWorld",
                BindingFlags.Public | BindingFlags.Instance);
            if (leasedProperty != null && (bool)leasedProperty.GetValue(Receiver))
            {
                InvokeReceiver("RestoreActiveAvatarFromWorld", HomeAnchor);
            }
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(worldOwner);
            UnityEngine.Object.DestroyImmediate(homeAnchor);
            UnityEngine.Object.DestroyImmediate(originalParent);
            if (avatar != null)
            {
                UnityEngine.Object.DestroyImmediate(avatar);
            }
        }
    }
}
