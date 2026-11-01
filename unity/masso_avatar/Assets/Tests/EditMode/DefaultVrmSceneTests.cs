using System;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;

public sealed class DefaultVrmSceneTests
{
    private const string ScenePath =
        "Assets/MaasoAvatar/Scenes/Companion.unity";
    private const string ModelPath =
        "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private const string ControllerPath =
        "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";

    [Test]
    public void CompanionSceneBindsTheReviewedVrmAsTheOnlyAvatar()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Assert.That(scene.isLoaded, Is.True);

        Vrm10Instance[] vrms = UnityEngine.Object.FindObjectsByType<Vrm10Instance>(
            FindObjectsInactive.Include,
            FindObjectsSortMode.None);
        Assert.That(vrms, Has.Length.EqualTo(1));
        Vrm10Instance vrm = vrms[0];
        GameObject source = PrefabUtility.GetCorrespondingObjectFromSource(
            vrm.gameObject);
        Assert.That(source, Is.Not.Null);
        Assert.That(AssetDatabase.GetAssetPath(source), Is.EqualTo(ModelPath));

        Animator animator = vrm.GetComponentInChildren<Animator>(true);
        Assert.That(animator, Is.Not.Null);
        Assert.That(animator.avatar, Is.Not.Null);
        Assert.That(animator.avatar.isHuman, Is.True);
        Assert.That(animator.avatar.isValid, Is.True);
        Assert.That(
            AssetDatabase.GetAssetPath(animator.runtimeAnimatorController),
            Is.EqualTo(ControllerPath));

        Component receiver = FindReceiver();
        Assert.That(receiver, Is.Not.Null);
        SerializedObject serialized = new(receiver);
        Assert.That(
            serialized.FindProperty("avatarRoot").objectReferenceValue,
            Is.SameAs(vrm.transform));
        Assert.That(
            serialized.FindProperty("bundledVrmInstance").objectReferenceValue,
            Is.SameAs(vrm));
    }

    [Test]
    public void PointerGazeDrivesVrmEyesAfterUniVrmLateProcessing()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm =
            UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        Assert.That(vrm, Is.Not.Null);
        Assert.That(receiver, Is.Not.Null);

        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");
        Animator animator = vrm.GetComponentInChildren<Animator>(true);
        Transform leftEye = animator.GetBoneTransform(HumanBodyBones.LeftEye);
        Transform rightEye = animator.GetBoneTransform(HumanBodyBones.RightEye);
        Assert.That(leftEye, Is.Not.Null);
        Assert.That(rightEye, Is.Not.Null);

        vrm.Runtime.LookAt.SetYawPitchManually(0f, 0f);
        vrm.Runtime.Process();
        Quaternion leftCentered = leftEye.localRotation;
        Quaternion rightCentered = rightEye.localRotation;

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0.8,\"eyeY\":0.8,\"headX\":0,\"headY\":0,\"headRoll\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();

        Assert.That(vrm.Runtime.LookAt.Yaw, Is.LessThan(-60f));
        Assert.That(vrm.Runtime.LookAt.Pitch, Is.GreaterThan(60f));
        Assert.That(
            Quaternion.Angle(leftCentered, leftEye.localRotation),
            Is.GreaterThan(5f));
        Assert.That(
            Quaternion.Angle(rightCentered, rightEye.localRotation),
            Is.GreaterThan(5f));

        Quaternion leftRightUp = leftEye.localRotation;
        Quaternion rightRightUp = rightEye.localRotation;
        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":-0.8,\"eyeY\":-0.8,\"headX\":0,\"headY\":0,\"headRoll\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();

        Assert.That(vrm.Runtime.LookAt.Yaw, Is.GreaterThan(60f));
        Assert.That(vrm.Runtime.LookAt.Pitch, Is.LessThan(-60f));
        Assert.That(
            Quaternion.Angle(leftCentered, leftEye.localRotation),
            Is.GreaterThan(5f));
        Assert.That(
            Quaternion.Angle(rightCentered, rightEye.localRotation),
            Is.GreaterThan(5f));
        Assert.That(
            Quaternion.Angle(leftRightUp, leftEye.localRotation),
            Is.GreaterThan(10f));
        Assert.That(
            Quaternion.Angle(rightRightUp, rightEye.localRotation),
            Is.GreaterThan(10f));

        SendCommand(receiver, Payload("clearGaze", "{}"));
        CompleteGazeTransition(receiver);
        vrm.Runtime.Process();
        Assert.That(vrm.Runtime.LookAt.Yaw, Is.EqualTo(0f).Within(0.001f));
        Assert.That(vrm.Runtime.LookAt.Pitch, Is.EqualTo(0f).Within(0.001f));
    }

    [Test]
    public void PointerGazeUsesAvatarYawAndPitchWithoutAddingHeadRoll()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm =
            UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        Assert.That(vrm, Is.Not.Null);
        Assert.That(receiver, Is.Not.Null);

        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");
        Animator animator = vrm.GetComponentInChildren<Animator>(true);
        Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
        Assert.That(head, Is.Not.Null);

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0,\"eyeY\":0,\"headX\":0,\"headY\":0,\"headRoll\":0,\"upperBodyX\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();
        Quaternion centered = head.rotation;
        Vector3 avatarForward = vrm.transform.forward;
        Vector3 avatarRight = vrm.transform.right;
        Vector3 avatarUp = vrm.transform.up;

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0,\"eyeY\":0,\"headX\":0.8,\"headY\":0,\"headRoll\":0,\"upperBodyX\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();
        Quaternion yawDelta = head.rotation * Quaternion.Inverse(centered);
        Vector3 yawedForward = yawDelta * avatarForward;
        Vector3 yawedUp = yawDelta * avatarUp;
        Assert.That(
            Vector3.Dot(yawedForward, -avatarRight),
            Is.GreaterThan(0.2f),
            "positive screen X should visibly turn the front-facing Avatar toward screen right");
        Assert.That(
            Mathf.Abs(Vector3.Dot(yawedForward, avatarUp)),
            Is.LessThan(0.03f),
            "horizontal cursor movement must not introduce pitch");
        Assert.That(
            Vector3.Dot(yawedUp, avatarUp),
            Is.GreaterThan(0.99f),
            "horizontal cursor movement must not roll/tilt the head");

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0,\"eyeY\":0,\"headX\":-0.8,\"headY\":0,\"headRoll\":0,\"upperBodyX\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();
        Quaternion oppositeYawDelta = head.rotation * Quaternion.Inverse(centered);
        Vector3 oppositeYawedForward = oppositeYawDelta * avatarForward;
        Vector3 oppositeYawedUp = oppositeYawDelta * avatarUp;
        Assert.That(
            Vector3.Dot(oppositeYawedForward, avatarRight),
            Is.GreaterThan(0.2f),
            "negative screen X should turn the front-facing Avatar toward screen left");
        Assert.That(
            Mathf.Abs(Vector3.Dot(oppositeYawedForward, avatarUp)),
            Is.LessThan(0.03f));
        Assert.That(
            Vector3.Dot(oppositeYawedUp, avatarUp),
            Is.GreaterThan(0.99f));

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0,\"eyeY\":0,\"headX\":0,\"headY\":0.8,\"headRoll\":0,\"upperBodyX\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();
        Quaternion pitchDelta = head.rotation * Quaternion.Inverse(centered);
        Vector3 pitchedForward = pitchDelta * avatarForward;
        Vector3 pitchedRight = pitchDelta * avatarRight;
        Assert.That(
            Vector3.Dot(pitchedForward, avatarUp),
            Is.GreaterThan(0.15f),
            "positive screen Y should visibly raise the Avatar's head");
        Assert.That(
            Mathf.Abs(Vector3.Dot(pitchedForward, avatarRight)),
            Is.LessThan(0.03f),
            "vertical cursor movement must not introduce yaw");
        Assert.That(
            Vector3.Dot(pitchedRight, avatarRight),
            Is.GreaterThan(0.99f),
            "vertical cursor movement must not roll/tilt the head");

        SendCommand(receiver, Payload(
            "setGaze",
            "{\"eyeX\":0,\"eyeY\":0,\"headX\":0,\"headY\":-0.8,\"headRoll\":0,\"upperBodyX\":0}"));
        CompleteGazeTransition(receiver);
        InvokePrivate(receiver, "LateUpdate");
        vrm.Runtime.Process();
        Quaternion oppositePitchDelta = head.rotation * Quaternion.Inverse(centered);
        Vector3 oppositePitchedForward = oppositePitchDelta * avatarForward;
        Vector3 oppositePitchedRight = oppositePitchDelta * avatarRight;
        Assert.That(
            Vector3.Dot(oppositePitchedForward, avatarUp),
            Is.LessThan(-0.15f),
            "negative screen Y should visibly lower the Avatar's head");
        Assert.That(
            Mathf.Abs(Vector3.Dot(oppositePitchedForward, avatarRight)),
            Is.LessThan(0.03f));
        Assert.That(
            Vector3.Dot(oppositePitchedRight, avatarRight),
            Is.GreaterThan(0.99f));
    }

    [Test]
    public void BundledVrmReceivesMouthAndEmotionCommands()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm =
            UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        Assert.That(vrm, Is.Not.Null);
        Assert.That(receiver, Is.Not.Null);
        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");

        SendCommand(receiver, Payload(
            "setExpression",
            "{\"happy\":0.75,\"eyeOpen\":1.0}"));
        CompleteExpressionTransition(receiver);
        float silentSmile = vrm.Runtime.Expression.GetWeight(ExpressionKey.Happy);
        SendCommand(receiver, Payload("setMouthOpen", "{\"value\":0.72}"));

        Assert.That(silentSmile, Is.InRange(.4f, .65f));
        Assert.That(vrm.Runtime.Expression.GetWeight(ExpressionKey.Happy),
            Is.InRange(.2f, silentSmile - .05f),
            "The visible mouth corner yields to a large vowel while retaining the intended smile.");
        Assert.That(
            vrm.Runtime.Expression.GetWeight(ExpressionKey.Aa),
            Is.GreaterThanOrEqualTo(0.71f));
    }

    [Test]
    public void BundledVrmReceivesFiveVowelVisemesAndStopClearsThem()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm =
            UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        Assert.That(vrm, Is.Not.Null);
        Assert.That(receiver, Is.Not.Null);
        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");

        (string viseme, ExpressionKey key)[] cases =
        {
            ("aa", ExpressionKey.Aa),
            ("ih", ExpressionKey.Ih),
            ("ou", ExpressionKey.Ou),
            ("ee", ExpressionKey.Ee),
            ("oh", ExpressionKey.Oh),
        };
        foreach ((string viseme, ExpressionKey key) in cases)
        {
            SendCommand(receiver, Payload(
                "startVisemeTimeline",
                "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2]," +
                $"\"cues\":[{{\"frame\":0,\"viseme\":\"{viseme}\"}}]," +
                "\"frameRate\":30}"));
            Assert.That(
                vrm.Runtime.Expression.GetWeight(key),
                Is.GreaterThan(0.35f),
                viseme);
        }

        SendCommand(receiver, Payload("stopLipSync", "{}"));
        foreach ((string viseme, ExpressionKey key) in cases)
        {
            Assert.That(
                vrm.Runtime.Expression.GetWeight(key),
                Is.LessThan(0.001f),
                viseme);
        }
    }

    [Test]
    public void BundledVrmEmotionSpeechAndBlinkHaveConcurrentActualOutput()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm = UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");
        SendCommand(receiver, Payload("startVisemeTimeline",
            "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.2,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"ih\"}],\"frameRate\":30}"));
        float vowelInput = vrm.Runtime.Expression.GetWeight(ExpressionKey.Ih);
        SendCommand(receiver, Payload("setExpression",
            "{\"happy\":0.75,\"mouthOpen\":1,\"eyeOpen\":1}"));
        CompleteExpressionTransition(receiver);
        receiver.GetType().GetField("nextBlinkAt", BindingFlags.NonPublic | BindingFlags.Instance)
            .SetValue(receiver, 10f);
        InvokePrivate(receiver, "UpdateAutoBlinkAt", 10f);
        InvokePrivate(receiver, "UpdateAutoBlinkAt", 10.056f);
        vrm.Runtime.Process();

        Vrm10RuntimeExpression expression = vrm.Runtime.Expression;
        Assert.That(expression.GetWeight(ExpressionKey.Ih), Is.EqualTo(vowelInput).Within(0.001f));
        Assert.That(expression.GetWeight(ExpressionKey.Aa), Is.EqualTo(0f));
        float spokenSmile = expression.ActualWeights[ExpressionKey.Happy];
        Assert.That(spokenSmile, Is.InRange(.3f, .6f));
        Assert.That(expression.ActualWeights[ExpressionKey.Ih], Is.GreaterThan(0.05f),
            "VRM's declared emotion override may attenuate speech but its vowel remains active.");
        Assert.That(expression.ActualWeights[ExpressionKey.Blink], Is.GreaterThan(0.1f));

        InvokePrivate(receiver, "ApplyLipSyncFrame", 1f);
        vrm.Runtime.Process();
        Assert.That(expression.ActualWeights[ExpressionKey.Ih], Is.EqualTo(0f));
        Assert.That(expression.ActualWeights[ExpressionKey.Aa], Is.EqualTo(0f));
        Assert.That(expression.ActualWeights[ExpressionKey.Happy], Is.GreaterThan(spokenSmile),
            "Silent timeline frames return the smile's lateral range without altering silence.");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void VrmBlinkFallsBackToSeparateEyes(bool emptyCombinedPreset)
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm = UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        VRM10Object original = vrm.Vrm;
        VRM10Object copy = UnityEngine.Object.Instantiate(original);
        VRM10Expression emptyBlink = ScriptableObject.CreateInstance<VRM10Expression>();
        try
        {
            Assert.That(copy.Expression, Is.Not.SameAs(original.Expression));
            copy.Expression.Blink = emptyCombinedPreset ? emptyBlink : null;
            vrm.Vrm = copy;
            ExpectEditModeVrmMaterialInstantiationLogs();
            InvokePrivate(receiver, "Awake");
            receiver.GetType().GetField("nextBlinkAt", BindingFlags.NonPublic | BindingFlags.Instance)
                .SetValue(receiver, 10f);
            InvokePrivate(receiver, "UpdateAutoBlinkAt", 10f);
            InvokePrivate(receiver, "UpdateAutoBlinkAt", 10.056f);
            vrm.Runtime.Process();
            Assert.That(vrm.Runtime.Expression.GetWeight(ExpressionKey.Blink), Is.EqualTo(0f));
            Assert.That(vrm.Runtime.Expression.ActualWeights[ExpressionKey.BlinkLeft], Is.GreaterThan(0.99f));
            Assert.That(vrm.Runtime.Expression.ActualWeights[ExpressionKey.BlinkRight], Is.GreaterThan(0.99f));
            InvokePrivate(receiver, "UpdateAutoBlinkAt", 10.161f);
            vrm.Runtime.Process();
            Assert.That(vrm.Runtime.Expression.ActualWeights[ExpressionKey.BlinkLeft], Is.EqualTo(0f));
            Assert.That(vrm.Runtime.Expression.ActualWeights[ExpressionKey.BlinkRight], Is.EqualTo(0f));
        }
        finally
        {
            vrm.Vrm = original;
            UnityEngine.Object.DestroyImmediate(copy);
            UnityEngine.Object.DestroyImmediate(emptyBlink);
        }
    }

    [Test]
    public void ReceiverOwnsVrmLateUpdateOnlyWhileEnabled()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Vrm10Instance vrm = UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Component receiver = FindReceiver();
        vrm.UpdateType = Vrm10Instance.UpdateTypes.Update;
        ExpectEditModeVrmMaterialInstantiationLogs();
        InvokePrivate(receiver, "Awake");
        Assert.That(vrm.UpdateType, Is.EqualTo(Vrm10Instance.UpdateTypes.LateUpdate));
        InvokePrivate(receiver, "OnDisable");
        Assert.That(vrm.UpdateType, Is.EqualTo(Vrm10Instance.UpdateTypes.Update));
        InvokePrivate(receiver, "OnEnable");
        Assert.That(vrm.UpdateType, Is.EqualTo(Vrm10Instance.UpdateTypes.LateUpdate));
        var replacement = new GameObject("Non VRM replacement");
        try
        {
            InvokePrivate(receiver, "BindAvatarRoot", replacement.transform);
            Assert.That(vrm.UpdateType, Is.EqualTo(Vrm10Instance.UpdateTypes.Update));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(replacement);
        }
    }

    private static void CompleteExpressionTransition(Component receiver)
    {
        float startedAt = (float)receiver.GetType().GetField(
            "expressionTransitionStartedAt", BindingFlags.NonPublic | BindingFlags.Instance)
            .GetValue(receiver);
        InvokePrivate(receiver, "UpdateExpressionTransition", startedAt + 1f);
    }

    private static void CompleteGazeTransition(Component receiver)
    {
        float startedAt = (float)receiver.GetType().GetField(
            "gazeTransitionStartedAt", BindingFlags.NonPublic | BindingFlags.Instance)
            .GetValue(receiver);
        InvokePrivate(receiver, "UpdateGazeTransition", startedAt + 1f);
    }

    private static void InvokePrivate(object target, string methodName, params object[] arguments)
    {
        MethodInfo method = target.GetType().GetMethod(
            methodName,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(method, Is.Not.Null, methodName);
        method.Invoke(target, arguments);
    }

    private static Component FindReceiver()
    {
        Type receiverType = Type.GetType(
            "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
        Assert.That(receiverType, Is.Not.Null);
        return UnityEngine.Object.FindAnyObjectByType(receiverType) as Component;
    }

    private static void ExpectEditModeVrmMaterialInstantiationLogs()
    {
        Vrm10Instance vrm = UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
        Assert.That(vrm, Is.Not.Null);
        // Unity logs UniVRM's EditMode material access once per material slot.
        int materialAccessCount = vrm.GetComponentsInChildren<Renderer>()
            .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
            .Sum(renderer => renderer.sharedMaterials.Length);
        for (int index = 0; index < materialAccessCount; index++)
        {
            LogAssert.Expect(
                LogType.Error,
                new Regex("Instantiating material due to calling renderer\\.material"));
        }
    }

    private static void SendCommand(Component receiver, string payload)
    {
        MethodInfo method = receiver.GetType().GetMethod("OnFlutterCommand");
        Assert.That(method, Is.Not.Null);
        method.Invoke(receiver, new object[] { payload });
    }

    private static string Payload(string method, string json)
    {
        string escaped = json.Replace("\\", "\\\\").Replace("\"", "\\\"");
        return $"{{\"method\":\"{method}\",\"json\":\"{escaped}\"}}";
    }
}
