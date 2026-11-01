using System;
using Newtonsoft.Json.Linq;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Maaso.World;
using UniVRM10;
using UnityEngine;
using UnityEngine.Networking;

#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
using System.Runtime.InteropServices;
#endif

namespace Maaso.Avatar
{
    [DisallowMultipleComponent]
    // Submit the animated face and gaze before UniVRM's LateUpdate (11000).
    [DefaultExecutionOrder(10000)]
    public sealed class UnityAvatarCommandReceiver : MonoBehaviour
    {
        [SerializeField] private Transform avatarRoot;
        [SerializeField] private SkinnedMeshRenderer faceRenderer;
        [SerializeField] private Animator animator;
        [SerializeField] private Vrm10Instance bundledVrmInstance;
        [SerializeField] private UnityWorldLightingController worldLighting;
        private AgentSpaceController agentSpace;
        [SerializeField] private bool logCommands;
        [SerializeField] private bool preferDesignedIdle = true;
        [SerializeField] private string designedIdleStateName = "idle_shrug";
        [SerializeField, Range(0f, 1f)] private float mainIdleProbability = 0.8f;
        [SerializeField] private string[] idleVariantStateNames = Array.Empty<string>();
        [SerializeField, Range(1f, 12f)] private float idleStateMinSeconds = 3.5f;
        [SerializeField, Range(1f, 16f)] private float idleStateMaxSeconds = 6.5f;
        [SerializeField] private float idleActionHoldSeconds = 1.2f;
        [SerializeField] private bool autoBlink = true;
        [SerializeField, Range(1.5f, 8f)] private float blinkIntervalSeconds = 3.2f;
        [SerializeField, Range(0f, 3f)] private float blinkIntervalJitterSeconds = 1.1f;
        [SerializeField, Range(0.05f, 0.35f)] private float blinkDurationSeconds = 0.16f;

        private const float HeadGazeYawDegrees = 28f;
        private const float HeadGazePitchDegrees = 18f;
        private const float HeadGazeRollDegrees = 10f;
        private const float EyeGazeYawDegrees = 16f;
        private const float EyeGazePitchDegrees = 10f;
        // Normalized VRM LookAt input. Joy's ten-degree downward range makes
        // this a gentle 2.5-degree eye contact correction, without tilting the head.
        private const float HomeEyeContactVerticalBias = -0.25f;
        private const float ScreenHorizontalToAvatarYaw = -1f;
        private const float UpperBodyGazeYawDegrees = 12f;
        private const float UpperBodyGazeIdleWeight = 0.42f;
        private const float UpperBodyGazeActionWeight = 0.16f;
        private const float GazeOwnershipAngleToleranceDegrees = 0.02f;
        private const float ExpressionTransitionSeconds = 0.22f;
        private const float GazeTransitionSeconds = 0.16f;
        private const float ScreenTapMaximumAttentionSeconds = 5f;
        private const float ScreenTapReturnSeconds = .45f;
        private const float BlinkClosingFraction = 0.35f;
        private const int AvatarArbiterProtocolVersion = 1;
        private const int MaximumAvatarArbiterPayloadChars = 256 * 1024;
        private const int MaximumLipSyncFrames = 7200;
        private const int MaximumLipSyncVisemeCues = 2048;
        private const string LipSyncVisemeFormat = "vrm_viseme_v2";
        private const float LipSyncNoiseFloor = 0.025f;
        private const float LipSyncAmplitudeGamma = 0.58f;
        private const float LipSyncAmplitudeGain = 1.35f;
        private const float LipSyncCrossFadeFrames = 2f;
        private const long MaximumExactJsonInteger = 9007199254740991L;
        private static readonly HashSet<string> AvatarArbiterChannels = new()
        {
            "mouth",
            "expression",
            "gaze",
            "bodyGesture",
            "framing",
        };
        private static readonly HashSet<string> AvatarArbiterCommandFields = new()
        {
            "protocolVersion", "requestId", "ticket", "rendererId",
            "ownerToken", "commitToken", "accountGeneration",
            "rendererGeneration", "channel", "fingerprint", "payloadJson",
            "payloadSha256", "deadlineEpochMs", "clearsChannel",
        };
        private static readonly HashSet<string> AvatarArbiterResetFields = new()
        {
            "protocolVersion", "requestId", "requirementId", "rendererId",
            "targetOwnerToken", "commitToken", "retiredAccountGeneration",
            "retiredRendererGeneration", "targetAccountGeneration",
            "targetRendererGeneration", "payloadJson", "payloadSha256",
            "deadlineEpochMs",
        };
        private static readonly HashSet<string> AvatarArbiterExpressionFields = new()
        {
            "happy", "sad", "angry", "surprised", "love", "relaxed",
            "thinking", "tired", "mouthSmile", "mouthOpen", "eyeOpen",
            "browConcern",
        };
        private static readonly HashSet<string> AvatarArbiterGazeFields = new()
        {
            "eyeX", "eyeY", "headX", "headY", "headRoll", "upperBodyX",
        };
        private static readonly HashSet<string> AvatarArbiterClearPayloadFields =
            new() { "channel", "clear" };
        private static readonly HashSet<string> AvatarArbiterMouthPayloadFields =
            new() { "channel", "value" };
        private static readonly HashSet<string> AvatarArbiterLipPayloadFields =
            new() { "channel", "envelope", "frameRate" };
        private static readonly HashSet<string> AvatarArbiterPlaybackClockFields =
            new() { "channel", "playbackClock" };
        private static readonly HashSet<string> AvatarArbiterVisemePayloadFields =
            new() { "channel", "format", "envelope", "cues", "frameRate" };
        private static readonly HashSet<string> DirectVisemeTimelineFields =
            new() { "format", "envelope", "cues", "frameRate" };
        private static readonly HashSet<string> LipSyncVisemeCueFields =
            new() { "frame", "viseme" };
        private static readonly HashSet<string> AvatarArbiterExpressionPayloadFields =
            new() { "channel", "params" };
        private static readonly HashSet<string> AvatarArbiterGazePayloadFields =
            new() { "channel", "gaze" };
        private static readonly HashSet<string> AvatarArbiterBodyPayloadFields =
            new() { "channel", "gesture" };
        private static readonly HashSet<string> AvatarArbiterPerformancePayloadFields =
            new() { "channel", "gesture", "energy", "intensity", "emotion", "leaseExpiresAtEpochMs" };
        private static readonly HashSet<string> PerformanceBodyGestures = new()
        {
            "speech", "explain", "palms_open", "point_small", "chest", "point_self",
            "hand_to_chest", "wave", "cheer", "jump", "listen", "look_away", "nod",
            "shrug", "think", "dance", "clap", "laugh", "bow",
        };
        private static readonly HashSet<string> AvatarArbiterWorkPayloadFields =
            new() { "channel", "gesture", "workSessionId", "workPhase" };
        private static readonly HashSet<string> AvatarArbiterFramingPayloadFields =
            new() { "channel", "mode" };
        private static readonly string[] FaceBlendShapeProbeNames =
        {
            "A",
            "I",
            "U",
            "E",
            "O",
            "Fcl_MTH_A",
            "Fcl_MTH_I",
            "Fcl_MTH_U",
            "Fcl_MTH_E",
            "Fcl_MTH_O",
            "V_Open",
            "V_Wide",
            "V_Tight",
            "V_Tight_O",
            "mouthOpen1",
            "mouthOpen2",
            "Blink",
            "Blink1_L",
            "Blink1_R",
            "Blink2_L",
            "Blink2_R",
            "Eye_Blink_L",
            "Eye_Blink_R",
            "Mouth_Smile_L",
            "Mouth_Smile_R",
            "Facial_Smile_Default",
            "Facial_Angry1",
            "Facial_Chu",
            "jaw_open",
            "eyes_closed.01",
            "eyes_closed.02",
            "eyes_closed.03",
        };
        private static readonly string[] NativeMattMouthShapes =
        {
            "V_Open", "V_Wide", "V_Tight", "V_Tight_O", "V_Explosive", "V_Dental_Lip",
        };

        private static readonly string[][] MouthPpBlendShapeGroups = {
            new[] { "Fcl_MTH_P" }, new[] { "V_Explosive" }, new[] { "viseme_PP" }, new[] { "mouthClose" },
        };
        private static readonly string[][] MouthFfBlendShapeGroups = {
            new[] { "Fcl_MTH_F" }, new[] { "V_Dental_Lip" }, new[] { "viseme_FF" },
        };
        private static readonly string[][] HappyBlendShapeGroups =
        {
            new[] { "Fun" },
            new[] { "Joy(Yaeba)" },
        };

        private static readonly string[][] SadBlendShapeGroups =
        {
            new[] { "Brow_Raise_Inner_L", "Brow_Raise_Inner_R" },
            new[] { "mayuge1_L", "mayuge1_R" },
            new[] { "tareme" },
        };

        private static readonly string[][] AngryBlendShapeGroups =
        {
            new[] { "Brow_Drop_L", "Brow_Drop_R" },
            new[] { "Angry" },
            new[] { "Facial_Angry1" },
            new[] { "Facial_Angry2" },
            new[] { "tsurime" },
        };

        private static readonly string[][] SurprisedBlendShapeGroups =
        {
            new[] { "Eye_Wide_L", "Eye_Wide_R" },
            new[] { "Fcl_MTH_O" },
            new[] { "mouthOpen2" },
            new[] { "O" },
        };

        private static readonly string[][] LoveBlendShapeGroups =
        {
            new[] { "Facial_Chu" },
            new[] { "Blink_Smile" },
            new[] { "Blink_Smile1_L", "Blink_Smile1_R" },
            new[] { "Blink_Smile2_L", "Blink_Smile2_R" },
        };

        private static readonly string[][] RelaxedBlendShapeGroups =
        {
            new[] { "Eye_Squint_L", "Eye_Squint_R" },
            new[] { "Lower_Eyelid1_L", "Lower_Eyelid1_R" },
        };

        private static readonly string[][] ThinkingBlendShapeGroups =
        {
            new[] { "Brow_Raise_Outer_L", "Brow_Raise_Outer_R" },
            new[] { "mayuge2_L", "mayuge2_R" },
        };

        private static readonly string[][] TiredBlendShapeGroups =
        {
            new[] { "Lower_Eyelid2_L", "Lower_Eyelid2_R" },
        };

        private static readonly string[][] SmileBlendShapeGroups =
        {
            new[] { "Mouth_Smile_L", "Mouth_Smile_R" },
            new[] { "Face_Blendshape.Fcl_MTH_Fun" },
            new[] { "Fcl_MTH_Fun" },
            new[] { "Smile_L", "Smile_R" },
            new[] { "Smile2" },
            new[] { "Facial_Smile_Default" },
            new[] { "Facial_Smile1" },
            new[] { "Facial_Smile2" },
        };

        private static readonly string[][] MouthBlendShapeGroups =
        {
            new[] { "A" },
            new[] { "Fcl_MTH_A" },
            new[] { "mouthOpen1" },
            new[] { "mouthOpen2" },
            new[] { "Jaw" },
            new[] { "Facial_Blends.Jaw_Down" },
            new[] { "vrc.v_aa" },
            new[] { "phoneme_Ah" },
            new[] { "jaw_open" },
        };

        private static readonly string[][] MouthIhBlendShapeGroups =
        {
            new[] { "I" },
            new[] { "Fcl_MTH_I" },
            new[] { "vrc.v_ih" },
            new[] { "phoneme_Ih" },
            new[] { "phoneme_Ee" },
        };

        private static readonly string[][] MouthOuBlendShapeGroups =
        {
            new[] { "U" },
            new[] { "Fcl_MTH_U" },
            new[] { "vrc.v_ou" },
            new[] { "phoneme_Ou" },
            new[] { "phoneme_Oo" },
        };

        private static readonly string[][] MouthEeBlendShapeGroups =
        {
            new[] { "E" },
            new[] { "Fcl_MTH_E" },
            new[] { "vrc.v_E" },
            new[] { "vrc.v_ee" },
            new[] { "vrc.v_e" },
            new[] { "phoneme_E" },
        };

        private static readonly string[][] MouthOhBlendShapeGroups =
        {
            new[] { "O" },
            new[] { "Fcl_MTH_O" },
            new[] { "vrc.v_oh" },
            new[] { "phoneme_Oh" },
        };

        private static readonly string[][] BlinkBlendShapeGroups =
        {
            new[] { "Eye_Blink_L", "Eye_Blink_R" },
            new[] { "Blink" },
            new[] { "Blink1_L", "Blink1_R" },
            new[] { "Blink2_L", "Blink2_R" },
            new[] { "eyes_closed.01", "eyes_closed.02", "eyes_closed.03" },
        };

        private static readonly string[][] ConcernBlendShapeGroups =
        {
            new[] { "mayuge3_L", "mayuge3_R" },
        };

        private static readonly string[] EyeLookLeftBlendShapes =
        {
            "eye_look_left.L",
            "eye_look_left.R",
        };

        private static readonly string[] EyeLookRightBlendShapes =
        {
            "eye_look_right.L",
            "eye_look_right.R",
        };

        private static readonly string[] EyeLookUpBlendShapes =
        {
            "eye_look_up.L",
            "eye_look_up.R",
        };

        private static readonly string[] EyeLookDownBlendShapes =
        {
            "eye_look_down.L",
            "eye_look_down.R",
        };

        private readonly Dictionary<string, Transform> bones = new();
        private readonly Dictionary<Transform, Quaternion> baseRotations = new();
        private readonly Dictionary<Transform, Vector3> basePositions = new();
        private readonly Dictionary<Transform, AppliedGazeBoneState>
            appliedGazeBoneStates = new();
        private Vector3 baseRootPosition;
        private Quaternion baseRootRotation;
        private Vector3 baseRootScale = Vector3.one;
        private AvatarExpressionCommand currentExpression = AvatarExpressionCommand.Default;
        private AvatarExpressionCommand expressionTransitionStart = AvatarExpressionCommand.Default;
        private AvatarExpressionCommand expressionTarget = AvatarExpressionCommand.Default;
        private float expressionTransitionStartedAt;
        private bool expressionTransitionActive;
        private readonly AvatarFacialCalibration facialCalibration = new();
        private readonly AvatarPupilDynamics pupilDynamics = new();
        private GazeCommand currentGaze = GazeCommand.Center;
        private GazeCommand gazeTransitionStart = GazeCommand.Center;
        private GazeCommand gazeTarget = GazeCommand.Center;
        private float gazeTransitionStartedAt;
        private float gazeTransitionDuration = GazeTransitionSeconds;
        private bool gazeTransitionActive;
        private bool gazeReleasing;
        private bool gazeActive;
        private float screenTapGazeReleaseAt = -1f;
        private float screenTapGazeReturnBy = -1f;
        private bool screenTapGazeRequiresHome;
        private float mouthOpen;
        private float mouthVisemePp, mouthVisemeFf;
        private float mouthVisemeAa;
        private float mouthVisemeIh;
        private float mouthVisemeOu;
        private float mouthVisemeEe;
        private float mouthVisemeOh;
        private float[] lipSyncEnvelope;
        private LipSyncVisemeCue[] lipSyncVisemeCues;
        private int lipSyncVisemeCueIndex;
        private bool lipSyncUsesVisemeTimeline;
        private int lipSyncFrameRate = 30;
        private float lipSyncStartedAt;
        private bool lipSyncActive;
        private float nextBlinkAt = -1f;
        private float blinkStartedAt = -1f;
        private float autoBlinkWeight;
        private bool hasBaseRootPose;
        private float actionPoseHoldUntil;
        private readonly OpenAnnieMotionPlayback annieMotion = new();
        private readonly AvatarSpeechPlaybackClock speechPlaybackClock = new();
        private readonly AvatarSpeechGestureScheduler speechGestures = new();
        private readonly AvatarSpeechGestureAnimator speechGestureAnimator = new();
        private readonly AvatarUpperBodyInertializer upperBodyInertia = new();
        private readonly AvatarNormalizedArmPose normalizedArmPose = new();
        private OpenAnnieMotionLibrary.Entry normalizedPoseEntry;
        private bool normalizedPoseTorso;
        private bool normalizedPoseSpeech;
        private long normalizedPoseEpisode;
        private float normalizedPoseSeconds;
        private readonly AvatarConversationMotionPolicy conversationMotion = new();
        private readonly AvatarConversationalMicroMotion conversationalMicroMotion = new();
        private readonly AvatarFreeGestureCollisionGuard freeGestureCollision = new();
        private AvatarRigifyArmDeformation activeArmDeformation;
        private bool guardWasAppliedLastFrame;
        // Optional semantic episodes require a BODY lease. A mouth clock alone
        // never grants authority. The host's actual lease expiry is digest-bound
        // in the renderer payload, separately from its short delivery deadline.
        private string performanceCueGesture, performanceCueEnergy, performanceCueEmotion, performanceCueTurnId;
        private float performanceCueIntensity;
        private long performanceCueSequence, performanceCueDeadlineMs, performanceCueAppliedEpoch = -1;
        private bool performanceCueSemanticConsumed, performanceBodyChannel;
        private string acceptedSpeechTurnId;
        private long legacyPerformanceSequence;
        private OpenAnnieMotionLibrary performanceLibrary;
        private bool speechMouthBound, performanceInitialized, conversationHintsEnabled;
        private long speechGestureEpoch = -1, conversationPhaseSequence;
        private string conversationPolicyClip;
        private float nextIdleStateAt = -1f;
        private string activeDesignedIdleStateName;
        private readonly Queue<string> recentDesignedIdleStates = new();
        private bool designedIdleActive;
        private bool worldLocomotionActive;
        private bool temporaryTurnActive;
        private bool temporaryTurnReturning;
        private float temporaryTurnTransitionSeconds;
        private bool bodyPoseTransitionActive;
        private Vector3 bodyPoseStartPosition;
        private Vector3 bodyPoseTargetPosition;
        private Quaternion bodyPoseStartRotation = Quaternion.identity;
        private Quaternion bodyPoseTargetRotation = Quaternion.identity;
        private Vector3 bodyPoseStartScale = Vector3.one;
        private Vector3 bodyPoseTargetScale = Vector3.one;
        private float bodyPoseTransitionStartedAt;
        private float bodyPoseTransitionDurationSeconds;
        private Transform bundledAvatarRoot;
        private GameObject reviewedAvatarInstance;
        private AssetBundle reviewedAvatarBundle;
        private Vrm10Instance reviewedVrmInstance;
        private Vrm10Instance activeVrmInstance;
        private Vrm10Instance updateOrderVrmInstance;
        private Vrm10Instance.UpdateTypes previousVrmUpdateType;
        private Coroutine reviewedAvatarLoad;
        private int reviewedAvatarLoadGeneration;
        private string reviewedAvatarLoadRequestId;
        private bool avatarLeasedToWorld;
        private AvatarPresenceTransitionController presenceTransition;
        private LoginDoorwayTransitionController doorwayTransition;
        private int doorwayRendererGeneration;
        private readonly List<LoginDoorwayResult> doorwayFrameReceipts = new();
        private AvatarPhoneInteractionController phoneInteraction;
        private readonly AvatarVrmJawOwnership vrmJawOwnership = new();
        private readonly AvatarLocalVisibilityMask localVisibility = new();
        private int presenceRendererGeneration;
        private readonly List<AvatarPresenceResult> presenceFrameReceipts = new();
        private Transform avatarLeaseWorldParent;
        private Transform avatarLeaseHomeParent;
        private Vector3 avatarLeaseHomeLocalPosition;
        private Quaternion avatarLeaseHomeLocalRotation = Quaternion.identity;
        private Vector3 avatarLeaseHomeLocalScale = Vector3.one;
        private Animator avatarLeaseAnimator;
        private bool avatarLeaseAnimatorApplyRootMotion;
        private readonly Dictionary<string, long> avatarArbiterTicketHighWater =
            new();
        private readonly HashSet<string> avatarArbiterDirtyChannels = new();
        private readonly AvatarFurniturePoseController furniturePose = new();
        private AvatarDeskWorkDisplay deskWorkDisplay;
        private AvatarHumanoidFaceRestPose humanoidFaceRest;
        private AvatarHumanoidSourceIdlePose humanoidSourceIdle;
        private long furnitureObservationSequence;
        private float furnitureLastFrame;
        private static readonly HashSet<string> HostBackgroundWorkFields = new()
        {
            "requestId", "sessionId", "phase", "loadRequestId", "sequence", "issuedAtEpochMs", "deadlineEpochMs"
        };
        private readonly HashSet<string> endedHostBackgroundWorkSessions = new();
        private string hostBackgroundWorkLoadRequestId, pendingHostBackgroundWorkLoadRequestId;
        private string hostBackgroundWorkSessionId, hostBackgroundWorkSessionLoadRequestId;
        private bool hostBackgroundWorkEnding, hostBackgroundWorkPaused;
        private long hostBackgroundWorkSequence, hostBackgroundWorkNotBeforeUtcMs;
        [Serializable] private sealed class HostBackgroundWorkCommand
        {
            public string requestId, sessionId, phase, loadRequestId;
            public long sequence, issuedAtEpochMs, deadlineEpochMs;
        }
        [Serializable] private sealed class HostBackgroundWorkResult
        {
            public string method = "setBackgroundTaskWork", requestId, sessionId, phase, loadRequestId;
            public long sequence;
            public bool ok;
            public string code;
        }
        [Serializable] private sealed class HostBackgroundWorkObservation
        {
            public string method = "backgroundTaskWorkState", requestId, sessionId, loadRequestId;
            public string phase, furnitureId, sceneId, workSessionId;
            public long sequence;
        }
        [Serializable] private sealed class FurnitureObservation
        {
            public string method = "furnitureState", requestId, ownerToken, phase, furnitureId, sceneId, workSessionId;
            public bool ok = true;
            public long accountGeneration, rendererGeneration, sequence;
        }
        private string avatarArbiterOwnerToken = string.Empty;
        private long avatarArbiterAccountGeneration = -1;
        private long avatarArbiterRendererGeneration = -1;
        private long avatarArbiterRendererGenerationHighWater = -1;
        // A successful full reset can leave a bound, neutral owner dormant.
        // The proof belongs to that exact owner/scope/high-water, never merely
        // to the presence of an old token or an empty dirty-channel set.
        private bool avatarArbiterLegacyReleased = true;
        private string avatarArbiterLegacyReleasedOwnerToken = string.Empty;
        private long avatarArbiterLegacyReleasedAccountGeneration = -1;
        private long avatarArbiterLegacyReleasedRendererGeneration = -1;
        private long avatarArbiterLegacyReleasedHighWater = -1;

        public Transform ActiveAvatarRoot
        {
            get
            {
                EnsureAvatar();
                return avatarRoot;
            }
        }

        public bool IsAvatarLeasedToWorld => avatarLeasedToWorld;
        public bool IsWorldLocomotionActive => worldLocomotionActive;

#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
        [DllImport("__Internal")]
        private static extern void MaasoUnityAvatarReady();

        [DllImport("__Internal")]
        private static extern void MaasoUnityAvatarCommandResult(string payload);
#endif

        private void Awake()
        {
            EnsureAvatar();
            bundledAvatarRoot = avatarRoot;
            if (bundledVrmInstance == null && bundledAvatarRoot != null)
            {
                bundledVrmInstance = bundledAvatarRoot
                    .GetComponentInChildren<Vrm10Instance>(true);
            }
            BindAvatarRoot(bundledAvatarRoot);
        }

        private void Start()
        {
            EnsureAvatar();
            ApplyExpression();
            ScheduleNextBlink(Time.realtimeSinceStartup);
            NotifyNativeReady();
        }

        private void OnEnable()
        {
            ConfigureVrmUpdateOrder();
            facialCalibration.Bind(avatarRoot, activeVrmInstance,
                activeVrmInstance != null && activeVrmInstance == bundledVrmInstance,
                humanoidFaceRest, humanoidSourceIdle);
            BindPupilDynamics();
            ApplyExpression();
        }

        private void OnDisable()
        {
            ResetSpeechPerformance();
            annieMotion.Stop();
            InvalidateHostBackgroundWorkModel(clearPending: true);
            agentSpace?.CancelForReset();
            phoneInteraction?.Reset("renderer_disabled");
            presenceRendererGeneration++;
            FailPresenceFrameReceipts("renderer_disabled");
            presenceTransition?.CancelForReset("renderer_disabled");
            CancelLoginDoorway("renderer_disabled");
            deskWorkDisplay?.Dispose();
            deskWorkDisplay = null;
            ClearGaze(immediate: true);
            ResetExpressionTransition();
            autoBlinkWeight = 0f;
            blinkStartedAt = -1f;
            nextBlinkAt = -1f;
            StopLipSync();
            RestoreVrmUpdateOrder();
            facialCalibration.Clear();
            pupilDynamics.Dispose();
            humanoidSourceIdle?.Reset();
        }

        private void OnApplicationPause(bool paused)
        {
            hostBackgroundWorkPaused = paused;
            if (paused)
            {
                pupilDynamics.Reset();
                ClearSpeechPerformanceCue();
                conversationalMicroMotion.Reset();
                freeGestureCollision.Reset();
                ReleaseAmbientBodyPerformance();
                upperBodyInertia.Reset();
                normalizedArmPose.Release();
                normalizedPoseEntry = null;
                SuspendHostBackgroundWork();
                deskWorkDisplay?.Dispose();
            }
            else if (furniturePose.DisplayWorkAnchor != null) ReportFurnitureState();
        }

        private void Update()
        {
            // Reverse the overlay ownership order before Animator evaluates.
            // Raw Rigify compensation runs after UniVRM and is restored first.
            activeArmDeformation?.RestoreBeforeAnimation();
            freeGestureCollision.RestoreBeforeAnimation();
            conversationalMicroMotion.RestoreBeforeAnimation();
            upperBodyInertia.BeforeAnimatorEvaluation();
            normalizedArmPose.RestoreOwnedPose();
            humanoidSourceIdle?.RestoreBeforeAnimation();
        }

        private void LateUpdate() => AdvancePresentationFrame(Time.realtimeSinceStartup, UtcEpochMilliseconds());

        // One production frame boundary, shared by continuous-motion regression
        // replay so tests include overlays, task ownership and render ordering.
        private void AdvancePresentationFrame(float now, long utc)
        {
            phoneInteraction?.RestorePose();
            // A newer task/turn may already own the shared hold. Releasing a
            // background clip must not clear that newer operation's deadline.
            bool ownPolicyWasPlaying = conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip;
            if (annieMotion.Advance(animator, now, AnnieMotionBlocked()) && ownPolicyWasPlaying)
                conversationMotion.PlaybackEnded(now);
            // Model-owned source FK is the baseline below conversational face,
            // gaze, speech and contact owners. Only this actual native idle's
            // current/next Animator contribution supplies correction weight.
            avatarRoot?.GetComponent<AvatarSourcePresentationFacing>()?.Apply();
            humanoidSourceIdle?.Apply(animator, SourceIdleBaselineAllowed());
            UpdateExpressionTransition(now);
            AdvancePupilDynamics(now);
            UpdateLipSync();
            UpdateAutoBlink();
            AdvanceSpeechPerformance(now);
            if (presenceTransition?.OwnsPresentation != true)
            {
                UpdateBodyPoseTransition();
                UpdateIdlePose();
            }
            upperBodyInertia.Bind(animator);
            bool sourceOwnsArms = AdvanceNormalizedArmPose();
            bool freeConversation = FreeConversationMotionAllowed(now);
            // Authored idle/listen cycles keep their original arm pose. Coarse
            // collision envelopes only adjust an active free speech layer.
            bool guardAllowed = freeConversation && !sourceOwnsArms && speechGestureAnimator.ActiveId != null;
            bool ownPolicy = conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip;
            bool routineExit = !AnnieMotionBlocked() && !temporaryTurnActive &&
                (!annieMotion.Active || ownPolicy) && (now >= actionPoseHoldUntil || ownPolicy);
            if (guardWasAppliedLastFrame && !guardAllowed && routineExit)
                upperBodyInertia.RequestPresentedTransition();
            upperBodyInertia.Apply(now, !AnnieMotionBlocked());
            conversationalMicroMotion.Apply(now, freeConversation && !gazeActive && !sourceOwnsArms);
            // Clearance recovers continuously within anatomical limits. A
            // coarse envelope overlap must never stop/restart the speech layer.
            freeGestureCollision.ApplyAt(now, guardAllowed);
            guardWasAppliedLastFrame = freeGestureCollision.HasOwnedWrites;
            upperBodyInertia.CapturePresentedPose();
            AdvanceScreenTapAttention(now);
            UpdateGazeTransition(now);
            if (gazeActive)
            {
                ApplyGazePose();
            }
            else
            {
                RestoreOwnedGazePose();
                ApplyHomeEyeContact();
            }
            StabilizeWorldLeaseRootPose();
            // Character Creator's vowel morphs articulate the lips; its JawRoot
            // still needs the imported local +Z hinge for teeth and tongue.
            if (activeVrmInstance == null) humanoidFaceRest?.Apply(
                Mathf.Max(mouthVisemeFf * .08f, Mathf.Max(mouthOpen,
                    Mathf.Max(mouthVisemeAa, Mathf.Max(mouthVisemeOh, mouthVisemeOu)))) *
                (1f - Mathf.Clamp01(mouthVisemePp * 2f)));
            vrmJawOwnership.Apply();
            ApplyFacialCompanions();
            presenceTransition?.Advance(now, utc);
            doorwayTransition?.Advance(now, utc);
            furniturePose.PreserveUpperBodyGesture = now < actionPoseHoldUntil;
            furniturePose.Advance(now, furnitureLastFrame > 0 ? Mathf.Clamp(now - furnitureLastFrame, 0, .1f) : 0);
            deskWorkDisplay?.Advance(now);
            furnitureLastFrame = now;
            phoneInteraction?.Advance(now, utc);
            localVisibility.Apply(avatarRoot, presenceTransition?.IsHidden == true);
        }

        public void OnFlutterCommand(string payload)
        {
            if (string.IsNullOrWhiteSpace(payload))
            {
                return;
            }

            if (!logCommands)
            {
                Dispatch(payload);
            }
            else
            {
                Debug.Log($"[UnityAvatar] command {payload}");
                Dispatch(payload);
            }
        }

        private static void NotifyNativeReady()
        {
#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
            MaasoUnityAvatarReady();
#elif UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                using (AndroidJavaClass unityPlayer = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (AndroidJavaObject activity = unityPlayer.GetStatic<AndroidJavaObject>("currentActivity"))
                {
                    activity?.Call("emitUnityAvatarReady");
                }
            }
            catch (Exception exception)
            {
                Debug.LogWarning($"[UnityAvatar] ready callback failed: {exception.Message}");
            }
#elif UNITY_STANDALONE_OSX && !UNITY_EDITOR
            DesktopUnitySidecarBridge.ReportAvatarReady();
#elif UNITY_STANDALONE_WIN && !UNITY_EDITOR
            WindowsUnityAvatarMessageBridge.ReportAvatarReady();
#else
            Debug.Log("[UnityAvatar] receiver ready");
#endif
        }

        private void Dispatch(string payload)
        {
            CommandEnvelope envelope = FromJson<CommandEnvelope>(payload);
            string method = envelope.method ?? string.Empty;
            string json = string.IsNullOrWhiteSpace(envelope.json) ? "{}" : envelope.json;

            if (method == "avatarArbiterCommand")
            {
                DispatchAvatarArbiterCommand(json);
                return;
            }
            if (method == "avatarArbiterReset")
            {
                DispatchAvatarArbiterReset(json);
                return;
            }

            EnsureAvatar();

            // Home chrome can reappear while this same actor is still walking
            // home. Ordinary chat gestures and camera choices do not retire or
            // retarget that journey. Viewport parameters and explicit cleanup
            // keep their existing paths; speech and face channels remain live.
            if (agentSpace?.IsReturningHome == true &&
                (method is "setBodyPose" or "playMotion" or "playMotionSequence" or
                 "playAnimationClip" or "playPrimitive" or "setHandIkTarget" or
                 "reactToScreenTap" or "setFraming" or "setWorldCamera")) return;

            if(method is "enterAgentSpace" or "leaveAgentSpace")recentDesignedIdleStates.Clear();
            if (doorwayTransition?.OwnsCamera == true &&
                (method == "enterAgentSpace"))
                CancelLoginDoorway("scene_takeover");
            if (doorwayTransition?.OwnsCamera == true &&
                (method == "setBodyPose" || method == "playMotion" || method == "playMotionSequence" ||
                 method == "playAnimationClip" || method == "playPrimitive" || method == "setFraming" ||
                 method == "reactToScreenTap")) return;
            if (method == "setFraming")
                ReleaseStartupPresenceForScene(FromJson<FramingCommand>(json)?.mode ?? string.Empty);
            if (presenceTransition?.OwnsPresentation == true &&
                (method == "setBodyPose" || method == "playMotion" || method == "playMotionSequence" ||
                 method == "playAnimationClip" || method == "playPrimitive" || method == "setFraming" ||
                 method == "setHandIkTarget" || method == "reactToScreenTap")) return;

            // Late conversational/idle commands can arrive after the task has
            // acquired the desk. They must not move its body or replace the
            // typing clip; task end still uses its dedicated session command.
            if ((hostBackgroundWorkSessionId != null || furniturePose.IsReturningFromWork) && furniturePose.Active &&
                (method is "setBodyPose" or "playMotion" or "playMotionSequence" or
                 "playAnimationClip" or "playPrimitive" or "setHandIkTarget" or "reactToScreenTap")) return;

            switch (method)
            {
                case "setLocalAvatarVisible":
                    bool locallyVisible = FromJson<LocalAvatarVisibilityCommand>(json).visible;
                    if (!locallyVisible) SuspendHostBackgroundWork();
                    if (!locallyVisible) agentSpace?.CancelForReset();
                    localVisibility.SetVisible(locallyVisible);
                    if (!locallyVisible) { phoneInteraction?.Reset("local_avatar_hidden"); CancelLoginDoorway("avatar_hidden"); }
                    localVisibility.Apply(avatarRoot, presenceTransition?.IsHidden == true);
                    if (locallyVisible && furniturePose.DisplayWorkAnchor != null) ReportFurnitureState();
                    break;
                case "setPhoneInteraction":
                    SetPhoneInteraction(FromJson<AvatarPhoneCommand>(json));
                    break;
                case "setBackgroundTaskWork":
                    SetHostBackgroundTaskWork(json);
                    break;
                case "transitionLoginDoorway":
                    TransitionLoginDoorway(FromJson<LoginDoorwayCommand>(json));
                    break;
                case "transitionPresence":
                    TransitionPresence(FromJson<AvatarPresenceCommand>(json));
                    break;
                case "setExpression":
                    SetExpression(FromJson<AvatarExpressionCommand>(json));
                    break;
                case "setMouthOpen":
                    SetMouthOpen(FromJson<MouthOpenCommand>(json).value);
                    break;
                case "startLipSync":
                    StartLipSync(FromJson<LipSyncCommand>(json));
                    break;
                case "syncSpeechPlaybackClock":
                    if (HostBackgroundWorkAuthorityReleased() && AvatarSpeechPlaybackClockPacket.TryParse(json, out var clockPacket))
                        SyncSpeechPlaybackClock(clockPacket);
                    break;
                case "setConversationPhase":
                    if (HostBackgroundWorkAuthorityReleased()) SetConversationPhase(json);
                    break;
                case "startVisemeTimeline":
                    LipSyncCommand visemeTimeline = FromJson<LipSyncCommand>(json);
                    if (ValidateDirectVisemeTimeline(visemeTimeline, json))
                    {
                        StartVisemeTimeline(visemeTimeline);
                    }
                    break;
                case "stopLipSync":
                    StopLipSync();
                    break;
                case "setGaze":
                    ApplyGaze(FromJson<GazeCommand>(json));
                    break;
                case "clearGaze":
                    ClearGaze();
                    break;
                case "playPrimitive":
                    PlayPrimitive(FromJson<PrimitiveCommand>(json));
                    break;
                case "playAnimationClip":
                    PlayAnimationClip(FromJson<AnimationClipCommand>(json));
                    break;
                case "reactToScreenTap":
                    ReactToScreenTap(FromJson<ScreenTapCommand>(json));
                    break;
                case "setHandIkTarget":
                    SetHandTarget(FromJson<HandTargetCommand>(json));
                    break;
                case "setBodyPose":
                    SetBodyPose(FromJson<BodyPoseCommand>(json));
                    break;
                case "playMotion":
                    PlayMotion(FromJson<MotionCommand>(json));
                    break;
                case "playMotionSequence":
                    PlayMotionSequence(FromJson<MotionSequenceCommand>(json));
                    break;
                case "setViewportSafeArea":
                    SetViewportSafeArea(FromJson<ViewportSafeAreaCommand>(json));
                    break;
                case "setFraming":
                    SetFraming(FromJson<FramingCommand>(json));
                    break;
                case "setWorldCamera":
                    EnsureAgentSpace().SetFraming(
                        FromJson<FramingCommand>(json).mode);
                    break;
                case "setWorldTimeOfDay":
                    SetWorldTimeOfDay(FromJson<WorldTimeOfDayCommand>(json));
                    break;
                case "enterAgentSpace":
                case "leaveAgentSpace":
                case "requestAgentSpaceMoveAtScreenPoint":
                    EnsureAgentSpace().ExecuteAsync(method, AgentSpaceController.ParseCommand(json),
                        result => NotifyCommandResult(JsonUtility.ToJson(result)));
                    break;
                case "loadAvatar":
                    agentSpace?.CancelForReset();
                    LoadAvatar(FromJson<AvatarLoadCommand>(json));
                    break;
                case "prepareView":
                case "resume":
                    break;
                case "pause":
                    agentSpace?.CancelForReset();
                    CancelLoginDoorway("application_paused");
                    break;
                default:
                    if (logCommands)
                    {
                        Debug.LogWarning($"[UnityAvatar] unsupported command {method}");
                    }

                    break;
            }
        }

        private void DispatchAvatarArbiterCommand(string json)
        {
            AvatarArbiterCommand command = FromJson<AvatarArbiterCommand>(json);
            string validationCode = ValidateAvatarArbiterCommand(command, json);
            if (!string.IsNullOrEmpty(validationCode))
            {
                NotifyAvatarArbiterCommandResult(command, false, validationCode);
                return;
            }

            bool firstOwner = string.IsNullOrEmpty(avatarArbiterOwnerToken);
            bool sameOwner = !firstOwner &&
                FixedTokenEquals(avatarArbiterOwnerToken, command.ownerToken) &&
                avatarArbiterAccountGeneration == command.accountGeneration &&
                avatarArbiterRendererGeneration == command.rendererGeneration;
            bool cleanTransfer = !firstOwner && !sameOwner &&
                avatarArbiterDirtyChannels.Count == 0 &&
                command.rendererGeneration > avatarArbiterRendererGenerationHighWater;
            if (!firstOwner && !sameOwner && !cleanTransfer)
            {
                NotifyAvatarArbiterCommandResult(command, false, "owner_mismatch");
                return;
            }
            if (firstOwner &&
                command.rendererGeneration <= avatarArbiterRendererGenerationHighWater)
            {
                NotifyAvatarArbiterCommandResult(command, false, "owner_mismatch");
                return;
            }

            if (cleanTransfer)
            {
                avatarArbiterTicketHighWater.Clear();
            }
            long priorTicket = avatarArbiterTicketHighWater.TryGetValue(
                command.channel,
                out long currentTicket)
                ? currentTicket
                : 0L;
            if (command.ticket <= priorTicket)
            {
                NotifyAvatarArbiterCommandResult(command, false, "stale_ticket");
                return;
            }

            // Final receiver-side fence. No renderer lookup or mutation happens
            // before all ownership, ticket, digest, and deadline fields pass.
            if (command.deadlineEpochMs < UtcEpochMilliseconds())
            {
                NotifyAvatarArbiterCommandResult(command, false, "deadline_expired");
                return;
            }

            if (firstOwner || cleanTransfer)
            {
                avatarArbiterOwnerToken = command.ownerToken;
                avatarArbiterAccountGeneration = command.accountGeneration;
                avatarArbiterRendererGeneration = command.rendererGeneration;
                avatarArbiterRendererGenerationHighWater =
                    command.rendererGeneration;
            }
            // Advance before mutation. A thrown or partial renderer write can
            // never be replayed as a fresh ticket; Dart will require reset.
            avatarArbiterTicketHighWater[command.channel] = command.ticket;
            avatarArbiterLegacyReleased = false;
            if (agentSpace?.IsReturningHome == true &&
                (command.channel == "bodyGesture" || command.channel == "framing"))
            {
                // Consume the fully validated ticket without replacing the
                // returning scene's body/camera owner. A mutation failure would
                // force an authority reset, which itself cancels the journey.
                // Neutral channel cleanup is acknowledged without touching the
                // live walking pose or lens; stale tickets still cannot replay.
                if (command.clearsChannel)
                    avatarArbiterDirtyChannels.Remove(command.channel);
                NotifyAvatarArbiterCommandResult(command, true, string.Empty);
                return;
            }
            try
            {
                AvatarArbiterRendererPayload rendererPayload =
                    FromJson<AvatarArbiterRendererPayload>(command.payloadJson);
                bool softPerformance = command.channel == "bodyGesture" &&
                    ((command.clearsChannel && performanceBodyChannel) ||
                     (!string.IsNullOrEmpty(rendererPayload.energy) && IsSpeechPerformanceGesture(rendererPayload.gesture)));
                if (!softPerformance) CancelHostBackgroundWork();
                EnsureAvatar();
                if (!ApplyAvatarArbiterMutation(command, rendererPayload))
                {
                    if (!command.clearsChannel)
                    {
                        avatarArbiterDirtyChannels.Add(command.channel);
                    }
                    NotifyAvatarArbiterCommandResult(
                        command,
                        false,
                        "mutation_failed");
                    return;
                }
                if (command.clearsChannel)
                {
                    avatarArbiterDirtyChannels.Remove(command.channel);
                }
                else
                {
                    avatarArbiterDirtyChannels.Add(command.channel);
                }
                NotifyAvatarArbiterCommandResult(command, true, string.Empty);
            }
            catch (Exception)
            {
                if (!command.clearsChannel)
                {
                    avatarArbiterDirtyChannels.Add(command.channel);
                }
                NotifyAvatarArbiterCommandResult(command, false, "mutation_failed");
            }
        }

        private void DispatchAvatarArbiterReset(string json)
        {
            AvatarArbiterReset command = FromJson<AvatarArbiterReset>(json);
            string validationCode = ValidateAvatarArbiterReset(command, json);
            if (!string.IsNullOrEmpty(validationCode))
            {
                NotifyAvatarArbiterResetResult(command, false, validationCode);
                return;
            }
            if (command.deadlineEpochMs < UtcEpochMilliseconds())
            {
                NotifyAvatarArbiterResetResult(command, false, "deadline_expired");
                return;
            }
            if (command.targetRendererGeneration <=
                avatarArbiterRendererGenerationHighWater)
            {
                NotifyAvatarArbiterResetResult(command, false, "reset_rejected");
                return;
            }
            if (!string.IsNullOrEmpty(avatarArbiterOwnerToken) &&
                (command.retiredAccountGeneration !=
                    avatarArbiterAccountGeneration ||
                 command.retiredRendererGeneration !=
                    avatarArbiterRendererGeneration))
            {
                NotifyAvatarArbiterResetResult(command, false, "reset_rejected");
                return;
            }

            avatarArbiterLegacyReleased = false;
            try
            {
                CancelHostBackgroundWork();
                EnsureAvatar();
                if (!ResetAvatarArbiterState())
                {
                    NotifyAvatarArbiterResetResult(
                        command,
                        false,
                        "mutation_failed");
                    return;
                }
                avatarArbiterOwnerToken = command.targetOwnerToken;
                avatarArbiterAccountGeneration = command.targetAccountGeneration;
                avatarArbiterRendererGeneration = command.targetRendererGeneration;
                avatarArbiterRendererGenerationHighWater =
                    command.targetRendererGeneration;
                avatarArbiterTicketHighWater.Clear();
                avatarArbiterDirtyChannels.Clear();
                avatarArbiterLegacyReleasedOwnerToken = avatarArbiterOwnerToken;
                avatarArbiterLegacyReleasedAccountGeneration = avatarArbiterAccountGeneration;
                avatarArbiterLegacyReleasedRendererGeneration = avatarArbiterRendererGeneration;
                avatarArbiterLegacyReleasedHighWater = avatarArbiterRendererGenerationHighWater;
                avatarArbiterLegacyReleased = true;
                CancelHostBackgroundWork();
                NotifyAvatarArbiterResetResult(command, true, string.Empty);
            }
            catch (Exception)
            {
                NotifyAvatarArbiterResetResult(command, false, "mutation_failed");
            }
        }

        private static string ValidateAvatarArbiterCommand(
            AvatarArbiterCommand command,
            string json)
        {
            if (!HasExactJsonObjectFields(
                    json,
                    AvatarArbiterCommandFields,
                    out Dictionary<string, string> commandFields) ||
                !HasValidAvatarArbiterCommandTokenTypes(commandFields) ||
                command == null ||
                command.protocolVersion != AvatarArbiterProtocolVersion ||
                !IsBoundedIdentifier(command.requestId, 96) ||
                !IsBoundedIdentifier(command.rendererId, 96) ||
                !IsOpaqueToken(command.ownerToken) ||
                !IsOpaqueToken(command.commitToken) ||
                command.ticket <= 0L ||
                command.ticket > MaximumExactJsonInteger ||
                command.accountGeneration < 0L ||
                command.accountGeneration > MaximumExactJsonInteger ||
                command.rendererGeneration < 0L ||
                command.rendererGeneration > MaximumExactJsonInteger ||
                !AvatarArbiterChannels.Contains(command.channel) ||
                command.deadlineEpochMs <= 0L ||
                command.deadlineEpochMs > MaximumExactJsonInteger ||
                command.deadlineEpochMs > UtcEpochMilliseconds() + 5000L ||
                command.payloadJson == null ||
                command.payloadJson.Length == 0 ||
                command.payloadJson.Length > MaximumAvatarArbiterPayloadChars ||
                !IsLowerHex(command.payloadSha256, 64) ||
                !FixedTokenEquals(
                    command.payloadSha256,
                    Sha256Hex(command.payloadJson)) ||
                (command.clearsChannel
                    ? !string.IsNullOrEmpty(command.fingerprint)
                    : !IsLowerHex(command.fingerprint, 16)))
            {
                return "invalid_command";
            }
            AvatarArbiterRendererPayload payload =
                FromJson<AvatarArbiterRendererPayload>(command.payloadJson);
            if (payload == null ||
                payload.channel != command.channel ||
                payload.clear != command.clearsChannel ||
                !ValidateAvatarArbiterRendererPayload(
                    payload,
                    command.payloadJson))
            {
                return "invalid_command";
            }
            return string.Empty;
        }

        private static string ValidateAvatarArbiterReset(
            AvatarArbiterReset command,
            string json)
        {
            if (!HasExactJsonObjectFields(
                    json,
                    AvatarArbiterResetFields,
                    out Dictionary<string, string> resetFields) ||
                !HasValidAvatarArbiterResetTokenTypes(resetFields) ||
                command == null ||
                command.protocolVersion != AvatarArbiterProtocolVersion ||
                !IsBoundedIdentifier(command.requestId, 96) ||
                !IsBoundedIdentifier(command.rendererId, 96) ||
                !IsOpaqueToken(command.targetOwnerToken) ||
                !IsOpaqueToken(command.commitToken) ||
                command.requirementId <= 0L ||
                command.requirementId > MaximumExactJsonInteger ||
                command.retiredAccountGeneration < 0L ||
                command.retiredAccountGeneration > MaximumExactJsonInteger ||
                command.retiredRendererGeneration < 0L ||
                command.retiredRendererGeneration > MaximumExactJsonInteger ||
                command.targetAccountGeneration < 0L ||
                command.targetAccountGeneration > MaximumExactJsonInteger ||
                command.targetRendererGeneration <=
                    command.retiredRendererGeneration ||
                command.targetRendererGeneration > MaximumExactJsonInteger ||
                command.deadlineEpochMs <= 0L ||
                command.deadlineEpochMs > MaximumExactJsonInteger ||
                command.deadlineEpochMs > UtcEpochMilliseconds() + 5000L ||
                command.payloadJson != "{\"reset\":true}" ||
                !IsLowerHex(command.payloadSha256, 64) ||
                !FixedTokenEquals(
                    command.payloadSha256,
                    Sha256Hex(command.payloadJson)))
            {
                return "reset_rejected";
            }
            return string.Empty;
        }

        private static bool ValidateAvatarArbiterRendererPayload(
            AvatarArbiterRendererPayload payload,
            string json)
        {
            if (payload.clear)
            {
                return HasExactJsonObjectFields(
                        json,
                        AvatarArbiterClearPayloadFields,
                        out Dictionary<string, string> clearFields) &&
                    IsJsonStringToken(clearFields["channel"]) &&
                    clearFields["clear"] == "true";
            }
            switch (payload.channel)
            {
                case "mouth":
                    if (HasExactJsonObjectFields(json, AvatarArbiterPlaybackClockFields, out var playbackFields))
                        return IsJsonStringToken(playbackFields["channel"]) &&
                            AvatarSpeechPlaybackClockPacket.TryParse(playbackFields["playbackClock"], out _);
                    if (HasExactJsonObjectFields(
                            json,
                            AvatarArbiterLipPayloadFields,
                            out Dictionary<string, string> lipFields))
                    {
                        if (payload.envelope == null ||
                            payload.envelope.Length == 0 ||
                            payload.envelope.Length > 7200 ||
                            payload.frameRate < 1 || payload.frameRate > 120 ||
                            !IsJsonStringToken(lipFields["channel"]) ||
                            !IsJsonIntegerToken(lipFields["frameRate"]) ||
                            !IsJsonNumberArray(
                                lipFields["envelope"],
                                7200))
                        {
                            return false;
                        }
                        for (int index = 0; index < payload.envelope.Length; index++)
                        {
                            if (!IsFiniteUnit(payload.envelope[index])) return false;
                        }
                        return true;
                    }
                    if (HasExactJsonObjectFields(
                            json,
                            AvatarArbiterVisemePayloadFields,
                            out Dictionary<string, string> visemeFields))
                    {
                        return ValidateVisemeTimeline(
                            payload.format,
                            payload.envelope,
                            payload.cues,
                            payload.frameRate,
                            visemeFields,
                            includesChannel: true);
                    }
                    return HasExactJsonObjectFields(
                            json,
                            AvatarArbiterMouthPayloadFields,
                            out Dictionary<string, string> mouthFields) &&
                        IsJsonStringToken(mouthFields["channel"]) &&
                        IsJsonNumberToken(mouthFields["value"]) &&
                        IsFiniteUnit(payload.value);
                case "expression":
                    return HasExactJsonObjectFields(
                            json,
                            AvatarArbiterExpressionPayloadFields,
                            out Dictionary<string, string> expressionFields) &&
                        HasExactJsonObjectFields(
                            expressionFields["params"],
                            AvatarArbiterExpressionFields,
                            out Dictionary<string, string> expressionValues) &&
                        IsJsonStringToken(expressionFields["channel"]) &&
                        AreJsonNumberTokens(
                            expressionValues,
                            AvatarArbiterExpressionFields) &&
                        IsValidArbiterExpression(payload.@params);
                case "gaze":
                    return HasExactJsonObjectFields(
                            json,
                            AvatarArbiterGazePayloadFields,
                            out Dictionary<string, string> gazeFields) &&
                        HasExactJsonObjectFields(
                            gazeFields["gaze"],
                            AvatarArbiterGazeFields,
                            out Dictionary<string, string> gazeValues) &&
                        IsJsonStringToken(gazeFields["channel"]) &&
                        AreJsonNumberTokens(
                            gazeValues,
                            AvatarArbiterGazeFields) &&
                        IsValidArbiterGaze(payload.gaze);
                case "bodyGesture":
                    if (HasExactJsonObjectFields(json, AvatarArbiterPerformancePayloadFields, out var performanceFields))
                        return IsJsonStringToken(performanceFields["channel"]) &&
                            IsJsonStringToken(performanceFields["gesture"]) &&
                            IsJsonStringToken(performanceFields["energy"]) &&
                            IsJsonStringToken(performanceFields["emotion"]) &&
                            IsJsonNumberToken(performanceFields["intensity"]) &&
                            IsJsonIntegerToken(performanceFields["leaseExpiresAtEpochMs"]) &&
                            PerformanceBodyGestures.Contains(payload.gesture) &&
                            ValidPerformanceStyle(payload.energy, payload.emotion, payload.intensity) &&
                            payload.leaseExpiresAtEpochMs > UtcEpochMilliseconds() &&
                            payload.leaseExpiresAtEpochMs <= UtcEpochMilliseconds() + 5000;
                    if(HasExactJsonObjectFields(json,AvatarArbiterWorkPayloadFields,out Dictionary<string,string> workFields))
                    {
                        return IsJsonStringToken(workFields["channel"]) && IsJsonStringToken(workFields["gesture"]) &&
                            IsJsonStringToken(workFields["workSessionId"]) && IsJsonStringToken(workFields["workPhase"]) &&
                            IsLowerHex(payload.workSessionId,64) &&
                            ((payload.workPhase=="start" && payload.gesture=="work_desk") ||
                             (payload.workPhase=="end" && payload.gesture=="stand_up"));
                    }
                    return HasExactJsonObjectFields(
                            json,
                            AvatarArbiterBodyPayloadFields,
                            out Dictionary<string, string> bodyFields) &&
                        IsJsonStringToken(bodyFields["channel"]) &&
                        IsJsonStringToken(bodyFields["gesture"]) &&
                        IsBoundedIdentifier(payload.gesture, 64);
                case "framing":
                    return HasExactJsonObjectFields(
                            json,
                            AvatarArbiterFramingPayloadFields,
                            out Dictionary<string, string> framingFields) &&
                        IsJsonStringToken(framingFields["channel"]) &&
                        IsJsonStringToken(framingFields["mode"]) &&
                        IsBoundedIdentifier(payload.mode, 64);
                default:
                    return false;
            }
        }

        private static bool ValidateDirectVisemeTimeline(
            LipSyncCommand command,
            string json)
        {
            if (command == null ||
                !HasExactJsonObjectFields(
                    json,
                    DirectVisemeTimelineFields,
                    out Dictionary<string, string> fields))
            {
                return false;
            }
            return ValidateVisemeTimeline(
                command.format,
                command.envelope,
                command.cues,
                command.frameRate,
                fields,
                includesChannel: false);
        }

        private static bool ValidateVisemeTimeline(
            string format,
            float[] envelope,
            LipSyncVisemeCue[] cues,
            int frameRate,
            Dictionary<string, string> fields,
            bool includesChannel)
        {
            if (format != LipSyncVisemeFormat ||
                envelope == null ||
                envelope.Length == 0 ||
                envelope.Length > MaximumLipSyncFrames ||
                cues == null ||
                cues.Length == 0 ||
                cues.Length > MaximumLipSyncVisemeCues ||
                frameRate < 1 ||
                frameRate > 120 ||
                !IsJsonStringToken(fields["format"]) ||
                !IsJsonIntegerToken(fields["frameRate"]) ||
                !IsJsonNumberArray(fields["envelope"], MaximumLipSyncFrames) ||
                (includesChannel && !IsJsonStringToken(fields["channel"])))
            {
                return false;
            }
            for (int index = 0; index < envelope.Length; index++)
            {
                if (!IsFiniteUnit(envelope[index])) return false;
            }
            return IsValidVisemeCueArray(
                fields["cues"],
                cues,
                envelope.Length);
        }

        private static bool IsValidVisemeCueArray(
            string json,
            LipSyncVisemeCue[] cues,
            int envelopeLength)
        {
            if (string.IsNullOrEmpty(json) || cues == null) return false;
            int index = 0;
            if (json[index] != '[') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            int cueIndex = 0;
            int previousFrame = -1;
            while (index < json.Length && json[index] != ']')
            {
                if (cueIndex >= cues.Length ||
                    cueIndex >= MaximumLipSyncVisemeCues ||
                    !TryReadJsonObject(
                        json,
                        ref index,
                        0,
                        out Dictionary<string, string> cueFields) ||
                    !LipSyncVisemeCueFields.SetEquals(cueFields.Keys) ||
                    !IsJsonIntegerToken(cueFields["frame"]) ||
                    !IsJsonStringToken(cueFields["viseme"]) ||
                    !int.TryParse(cueFields["frame"], out int rawFrame))
                {
                    return false;
                }
                LipSyncVisemeCue cue = cues[cueIndex];
                if (cue == null ||
                    cue.frame != rawFrame ||
                    cue.frame < 0 ||
                    cue.frame >= envelopeLength ||
                    (cueIndex == 0 ? cue.frame != 0 : cue.frame <= previousFrame) ||
                    !IsSupportedLipSyncViseme(cue.viseme))
                {
                    return false;
                }
                previousFrame = cue.frame;
                cueIndex++;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] == ']') break;
                if (json[index] != ',') return false;
                index++;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] == ']') return false;
            }
            if (index >= json.Length || json[index] != ']') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            return cueIndex == cues.Length && cueIndex > 0 && index == json.Length;
        }

        private static bool IsSupportedLipSyncViseme(string viseme) =>
            viseme == "sil" ||
            viseme == "aa" ||
            viseme == "ih" ||
            viseme == "ou" ||
            viseme == "ee" ||
            viseme == "oh" || viseme == "pp" || viseme == "ff";

        private bool ApplyAvatarArbiterMutation(
            AvatarArbiterCommand command,
            AvatarArbiterRendererPayload payload)
        {
            if ((presenceTransition?.OwnsPresentation == true || doorwayTransition?.OwnsCamera == true) &&
                (command.channel == "bodyGesture" || command.channel == "framing"))
            {
                // An optional conversational beat must not fail the authority
                // and reset a character currently entering the scene.
                if (command.channel == "bodyGesture" && !string.IsNullOrEmpty(payload.energy) &&
                    IsSpeechPerformanceGesture(payload.gesture))
                { ClearSpeechPerformanceCue(); return true; }
                return command.clearsChannel;
            }
            if (command.clearsChannel)
            {
                return ClearAvatarArbiterChannel(command.channel);
            }
            switch (command.channel)
            {
                case "mouth":
                    // JsonUtility may allocate an empty nested class even when
                    // the JSON omits it. Presence must use its validated version.
                    if (payload.playbackClock?.protocolVersion == 1) return SyncSpeechPlaybackClock(payload.playbackClock);
                    if (payload.envelope != null && payload.envelope.Length > 0)
                    {
                        LipSyncCommand lipSync = new()
                        {
                            format = payload.format,
                            envelope = payload.envelope,
                            cues = payload.cues,
                            frameRate = payload.frameRate,
                        };
                        if (payload.format == LipSyncVisemeFormat)
                        {
                            StartVisemeTimeline(lipSync);
                        }
                        else
                        {
                            StartLipSync(lipSync);
                        }
                    }
                    else
                    {
                        SetMouthOpen(payload.value);
                    }
                    return activeVrmInstance != null || faceRenderer != null;
                case "expression":
                    SetExpression(payload.@params);
                    return activeVrmInstance != null || faceRenderer != null;
                case "gaze":
                    ApplyGaze(payload.gaze);
                    return true;
                case "bodyGesture":
                    if (!string.IsNullOrEmpty(payload.energy) && IsSpeechPerformanceGesture(payload.gesture))
                    {
                        bool queued = QueueSpeechPerformanceCue(payload.gesture, payload.emotion, payload.energy,
                            payload.intensity, command.ticket, payload.leaseExpiresAtEpochMs);
                        if (queued) performanceBodyChannel = true;
                        return queued;
                    }
                    ClearSpeechPerformanceCue();
                    performanceBodyChannel = false;
                    if(payload.workPhase=="start")return BeginBackgroundWork(payload.workSessionId);
                    if(payload.workPhase=="end")return furniturePose.EndWorkSession(payload.workSessionId,Time.realtimeSinceStartup);
                    if (AvatarFurniturePoseController.IsGesture(payload.gesture)) return BeginFurniture(payload.gesture);
                    if (furniturePose.Active && payload.gesture == "jump") return false;
                    PlayPrimitive(new PrimitiveCommand
                    {
                        type = payload.gesture,
                        options = string.IsNullOrEmpty(payload.energy) ? PrimitiveOptions.Default : new PrimitiveOptions
                        { intensity = payload.intensity, energy = payload.energy, emotion = payload.emotion },
                    });
                    return avatarRoot != null;
                case "framing":
                    FrontFullBodyCamera framing = FindFramingCamera();
                    if (framing == null) return false;
                    if(payload.mode=="desk_over_shoulder" &&
                        (furniturePose.WorkSessionId==null || furniturePose.Phase!="working" || !framing.HasDeskWorkAnchor))return false;
                    framing.SetFramingMode(payload.mode);
                    return true;
                default:
                    return false;
            }
        }

        private bool ClearAvatarArbiterChannel(string channel)
        {
            switch (channel)
            {
                case "mouth":
                    StopLipSync();
                    return activeVrmInstance != null || faceRenderer != null;
                case "expression":
                    SetExpression(AvatarExpressionCommand.Default);
                    return activeVrmInstance != null || faceRenderer != null;
                case "gaze":
                    ClearGaze();
                    return true;
                case "bodyGesture":
                    ResetAvatarArbiterBodyGesture();
                    return avatarRoot != null;
                case "framing":
                    FrontFullBodyCamera framing = FindFramingCamera();
                    if (framing == null) return false;
                    framing.SetFramingMode("hero_full_body");
                    return true;
                default:
                    return false;
            }
        }

        private bool BeginFurniture(string gesture)
        {
            EnsureAvatar();
            var worldCamera = FindFirstObjectByType<WorldCameraDirector>();
            if (!localVisibility.Visible || avatarLeasedToWorld ||
                presenceTransition?.OwnsPresentation == true || doorwayTransition?.OwnsCamera == true ||
                (worldCamera != null && worldCamera.isActiveAndEnabled && worldCamera.Phase != WorldCameraPhase.Home)) return false;
            var map = FindFirstObjectByType<PersistentWorldMapController>();
            var rig = AvatarFurnitureRig.Ensure(map);
            bool accepted = furniturePose.Begin(gesture, avatarRoot, animator, rig,
                Time.realtimeSinceStartup, _ => ReportFurnitureState(), SetWorldLocomotion);
            if (accepted && hostBackgroundWorkSessionId != null &&
                (hostBackgroundWorkEnding || furniturePose.WorkSessionId != hostBackgroundWorkSessionId))
                RetireHostBackgroundWorkBinding();
            return accepted;
        }

        private void SetHostBackgroundTaskWork(string json)
        {
            HostBackgroundWorkCommand command = FromJson<HostBackgroundWorkCommand>(json);
            long utc = UtcEpochMilliseconds();
            string code = ValidateHostBackgroundWork(command, json, utc);
            if (code.Length == 0 && !HostBackgroundWorkAuthorityReleased()) code = "authority_owned";
            if (code.Length == 0 && (string.IsNullOrEmpty(hostBackgroundWorkLoadRequestId) ||
                command.loadRequestId != hostBackgroundWorkLoadRequestId)) code = "model_stale";
            if (code.Length == 0 && command.sequence <= hostBackgroundWorkSequence) code = "stale_sequence";
            if (code.Length == 0 && command.phase == "start" && command.issuedAtEpochMs < hostBackgroundWorkNotBeforeUtcMs &&
                command.sessionId != hostBackgroundWorkSessionId)
                code = "session_ended";
            if (code == "deadline_expired" && command.phase == "end" &&
                HostBackgroundWorkAuthorityReleased() && command.loadRequestId == hostBackgroundWorkLoadRequestId &&
                command.sessionId == hostBackgroundWorkSessionId)
            {
                // A delayed stop cannot start anything. It may still release
                // its exact existing task, so timeout cannot strand typing.
                hostBackgroundWorkSequence = Math.Max(hostBackgroundWorkSequence, command.sequence);
                EndHostBackgroundWork(command);
            }
            if (code.Length == 0)
            {
                hostBackgroundWorkSequence = command.sequence;
                if (command.phase == "end")
                    code = EndHostBackgroundWork(command);
                else code = StartHostBackgroundWork(command);
            }
            NotifyCommandResult(JsonUtility.ToJson(new HostBackgroundWorkResult {
                requestId = command?.requestId, sessionId = command?.sessionId, phase = command?.phase,
                loadRequestId = command?.loadRequestId, sequence = command?.sequence ?? 0,
                ok = code.Length == 0, code = code,
            }));
        }

        private static string ValidateHostBackgroundWork(HostBackgroundWorkCommand command, string json, long utc)
        {
            if (command == null || !HasExactJsonObjectFields(json, HostBackgroundWorkFields, out var fields) ||
                !IsJsonStringToken(fields["requestId"]) || !IsJsonStringToken(fields["sessionId"]) ||
                !IsJsonStringToken(fields["phase"]) || !IsJsonStringToken(fields["loadRequestId"]) ||
                !IsJsonIntegerToken(fields["sequence"]) || !IsJsonIntegerToken(fields["issuedAtEpochMs"]) ||
                !IsJsonIntegerToken(fields["deadlineEpochMs"]) ||
                string.IsNullOrWhiteSpace(command.requestId) || command.requestId.Length > 128 ||
                string.IsNullOrWhiteSpace(command.loadRequestId) || command.loadRequestId.Length > 128 ||
                !IsLowerHex(command.sessionId, 64) || command.phase is not ("start" or "end") ||
                command.sequence <= 0 || command.sequence > MaximumExactJsonInteger ||
                command.issuedAtEpochMs <= 0 || command.issuedAtEpochMs > MaximumExactJsonInteger ||
                command.deadlineEpochMs <= command.issuedAtEpochMs || command.deadlineEpochMs > MaximumExactJsonInteger ||
                command.deadlineEpochMs - command.issuedAtEpochMs > 10000 || command.issuedAtEpochMs > utc + 1000)
                return "invalid_command";
            return utc >= command.deadlineEpochMs ? "deadline_expired" : string.Empty;
        }

        private bool HostBackgroundWorkAuthorityReleased() => string.IsNullOrEmpty(avatarArbiterOwnerToken) ||
            (avatarArbiterLegacyReleased &&
             FixedTokenEquals(avatarArbiterLegacyReleasedOwnerToken, avatarArbiterOwnerToken) &&
             avatarArbiterLegacyReleasedAccountGeneration == avatarArbiterAccountGeneration &&
             avatarArbiterLegacyReleasedRendererGeneration == avatarArbiterRendererGeneration &&
             avatarArbiterLegacyReleasedHighWater == avatarArbiterRendererGenerationHighWater);

        private string EndHostBackgroundWork(HostBackgroundWorkCommand command)
        {
            // Remember an end even if its start has not reached Unity. A later
            // command cannot revive this exact task session.
            endedHostBackgroundWorkSessions.Add(command.sessionId);
            if (hostBackgroundWorkSessionId != command.sessionId)
                return hostBackgroundWorkSessionId == null ? string.Empty : "session_mismatch";
            if (furniturePose.WorkSessionId != command.sessionId)
            {
                if (!hostBackgroundWorkEnding) RetireHostBackgroundWorkBinding();
                return string.Empty;
            }
            try
            {
                hostBackgroundWorkEnding = true;
                if (furniturePose.EndWorkSession(command.sessionId, Time.realtimeSinceStartup)) return string.Empty;
                RetireHostBackgroundWorkBinding();
                return "mutation_failed";
            }
            catch (Exception)
            {
                CancelHostBackgroundWork();
                return "mutation_failed";
            }
        }

        private string StartHostBackgroundWork(HostBackgroundWorkCommand command)
        {
            if (endedHostBackgroundWorkSessions.Contains(command.sessionId)) return "session_ended";
            if (!isActiveAndEnabled || avatarRoot == null || animator == null) return "not_ready";
            var worldCamera = FindFirstObjectByType<WorldCameraDirector>();
            if (hostBackgroundWorkPaused || !localVisibility.Visible || avatarLeasedToWorld ||
                phoneInteraction?.OwnsHands == true || presenceTransition?.OwnsPresentation == true ||
                doorwayTransition?.OwnsCamera == true ||
                (worldCamera != null && worldCamera.isActiveAndEnabled && worldCamera.Phase != WorldCameraPhase.Home))
                return "presentation_busy";
            if (hostBackgroundWorkSessionId == command.sessionId &&
                furniturePose.WorkSessionId == command.sessionId) return string.Empty;
            if (furniturePose.Active)
                return hostBackgroundWorkEnding ? "presentation_busy" : "user_pose_owned";
            hostBackgroundWorkSessionId = command.sessionId;
            hostBackgroundWorkSessionLoadRequestId = command.loadRequestId;
            hostBackgroundWorkEnding = false;
            try
            {
                if (BeginBackgroundWork(command.sessionId)) return string.Empty;
                RetireHostBackgroundWorkBinding();
                return "work_unavailable";
            }
            catch (Exception)
            {
                CancelHostBackgroundWork();
                return "mutation_failed";
            }
        }

        private void RetireHostBackgroundWorkBinding()
        {
            if (hostBackgroundWorkSessionId != null) endedHostBackgroundWorkSessions.Add(hostBackgroundWorkSessionId);
            hostBackgroundWorkSessionId = null;
            hostBackgroundWorkSessionLoadRequestId = null;
            hostBackgroundWorkEnding = false;
        }

        private bool HostBackgroundWorkOwnsPose() => hostBackgroundWorkSessionId != null &&
            (furniturePose.WorkSessionId == hostBackgroundWorkSessionId ||
             (hostBackgroundWorkEnding && furniturePose.Phase == "rising"));

        private void SuspendHostBackgroundWork()
        {
            // Hide/pause is a presentation boundary, not completion of the
            // admitted task. Keep its seat, root origin and return journey;
            // only an unseen queued start is fenced out by this boundary.
            hostBackgroundWorkNotBeforeUtcMs = Math.Max(hostBackgroundWorkNotBeforeUtcMs, UtcEpochMilliseconds() + 1);
            furnitureLastFrame = -1f;
            deskWorkDisplay?.SetWorking(false);
        }

        private void CancelHostBackgroundWork()
        {
            // A barrier also rejects a queued start whose session Unity has
            // never seen, without requiring a model reload after app resume.
            hostBackgroundWorkNotBeforeUtcMs = Math.Max(hostBackgroundWorkNotBeforeUtcMs, UtcEpochMilliseconds() + 1);
            if (hostBackgroundWorkSessionId == null) return;
            string session = hostBackgroundWorkSessionId;
            bool ownsPose = HostBackgroundWorkOwnsPose();
            endedHostBackgroundWorkSessions.Add(session);
            if (ownsPose)
            {
                hostBackgroundWorkEnding = true;
                furniturePose.ResetWorkToOrigin();
            }
            RetireHostBackgroundWorkBinding();
        }

        private void InvalidateHostBackgroundWorkModel(bool clearPending = false)
        {
            CancelHostBackgroundWork();
            hostBackgroundWorkLoadRequestId = null;
            if (clearPending) pendingHostBackgroundWorkLoadRequestId = null;
            hostBackgroundWorkSequence = 0;
            endedHostBackgroundWorkSessions.Clear();
        }

        private void ReportHostBackgroundWorkState()
        {
            if (hostBackgroundWorkSessionId == null || hostBackgroundWorkSessionLoadRequestId == null) return;
            string session = hostBackgroundWorkSessionId;
            bool retainsWork = furniturePose.WorkSessionId == session &&
                (furniturePose.Phase is "approaching" or "aligning" or "working");
            bool finishing = hostBackgroundWorkEnding && (furniturePose.Phase is "rising" or "standing");
            long sequence = ++furnitureObservationSequence;
            NotifyCommandResult(JsonUtility.ToJson(new HostBackgroundWorkObservation {
                requestId = "work-state-" + sequence, sessionId = session,
                loadRequestId = hostBackgroundWorkSessionLoadRequestId, phase = furniturePose.Phase,
                furnitureId = furniturePose.FurnitureId, sceneId = furniturePose.SceneId,
                sequence = sequence, workSessionId = retainsWork ? session : null,
            }));
            if ((!retainsWork && !finishing) || furniturePose.Phase == "standing")
                RetireHostBackgroundWorkBinding();
        }

        private bool BeginBackgroundWork(string sessionId)
        {
            EnsureAvatar();
            var worldCamera=FindFirstObjectByType<WorldCameraDirector>();
            if(!localVisibility.Visible || avatarLeasedToWorld ||
                phoneInteraction?.OwnsHands==true ||
                presenceTransition?.OwnsPresentation==true || doorwayTransition?.OwnsCamera==true ||
                (worldCamera!=null && worldCamera.isActiveAndEnabled && worldCamera.Phase!=WorldCameraPhase.Home))return false;
            var rig=AvatarFurnitureRig.Ensure(FindFirstObjectByType<PersistentWorldMapController>());
            return furniturePose.BeginWorkSession(sessionId,avatarRoot,animator,rig,Time.realtimeSinceStartup,
                _=>ReportFurnitureState(),SetWorldLocomotion);
        }

        private void ReportFurnitureState()
        {
            var displayAnchor = furniturePose.DisplayWorkAnchor;
            if (displayAnchor == null || hostBackgroundWorkPaused || !localVisibility.Visible) deskWorkDisplay?.SetWorking(false);
            else
            {
                var display = AvatarDeskWorkDisplay.Ensure(displayAnchor);
                if (deskWorkDisplay != display) deskWorkDisplay?.Dispose();
                deskWorkDisplay = display;
                deskWorkDisplay?.SetWorking(true);
            }
            FindFramingCamera()?.SetFurniturePoseActive(furniturePose.Phase != "standing");
            FindFramingCamera()?.SetDeskWorkAnchor(furniturePose.WorkAnchor);
            ReportHostBackgroundWorkState();
            if (string.IsNullOrEmpty(avatarArbiterOwnerToken)) return;
            long sequence = ++furnitureObservationSequence;
            NotifyCommandResult(JsonUtility.ToJson(new FurnitureObservation {
                requestId = "furniture-" + sequence, ownerToken = avatarArbiterOwnerToken,
                accountGeneration = avatarArbiterAccountGeneration,
                rendererGeneration = avatarArbiterRendererGeneration,
                phase = furniturePose.Phase, furnitureId = furniturePose.FurnitureId,
                workSessionId = furniturePose.WorkSessionId,
                sceneId = furniturePose.SceneId, sequence = sequence,
            }));
        }

        private bool ResetAvatarArbiterState()
        {
            ResetSpeechPerformance();
            agentSpace?.CancelForReset();
            CancelLoginDoorway("authority_reset");
            furniturePose.Reset();
            ResetExpressionTransition();
            pupilDynamics.Reset();
            StopLipSync();
            ClearGaze(immediate: true);
            ResetAvatarArbiterBodyGesture();
            FrontFullBodyCamera framing = FindFramingCamera();
            if (framing == null) return false;
            framing.SetFramingMode("hero_full_body");
            ApplyExpression();
            return avatarRoot != null &&
                (activeVrmInstance != null || faceRenderer != null);
        }

        private void ResetAvatarArbiterBodyGesture()
        {
            bool softPerformance = performanceBodyChannel;
            ClearSpeechPerformanceCue();
            performanceBodyChannel = false;
            if (softPerformance || presenceTransition?.OwnsPresentation == true) return;
            ReleaseAmbientBodyPerformance();
            annieMotion.Stop();
            CancelTemporaryTurn();
            bodyPoseTransitionActive = false;
            actionPoseHoldUntil = 0f;
            designedIdleActive = false;
            activeDesignedIdleStateName = string.Empty;
            nextIdleStateAt = -1f;
            foreach (KeyValuePair<Transform, Quaternion> entry in baseRotations)
            {
                if (entry.Key != null) entry.Key.localRotation = entry.Value;
            }
            foreach (KeyValuePair<Transform, Vector3> entry in basePositions)
            {
                if (entry.Key != null) entry.Key.localPosition = entry.Value;
            }
            if (!furniturePose.Active && !avatarLeasedToWorld && avatarRoot != null && hasBaseRootPose)
            {
                avatarRoot.localPosition = baseRootPosition;
                avatarRoot.localRotation = baseRootRotation;
                avatarRoot.localScale = baseRootScale;
            }
            TryStartDesignedIdle(designedIdleStateName);
        }

        private static bool HasValidAvatarArbiterCommandTokenTypes(
            Dictionary<string, string> fields) =>
            IsJsonIntegerToken(fields["protocolVersion"]) &&
            IsJsonStringToken(fields["requestId"]) &&
            IsJsonIntegerToken(fields["ticket"]) &&
            IsJsonStringToken(fields["rendererId"]) &&
            IsJsonStringToken(fields["ownerToken"]) &&
            IsJsonStringToken(fields["commitToken"]) &&
            IsJsonIntegerToken(fields["accountGeneration"]) &&
            IsJsonIntegerToken(fields["rendererGeneration"]) &&
            IsJsonStringToken(fields["channel"]) &&
            IsJsonStringToken(fields["fingerprint"]) &&
            IsJsonStringToken(fields["payloadJson"]) &&
            IsJsonStringToken(fields["payloadSha256"]) &&
            IsJsonIntegerToken(fields["deadlineEpochMs"]) &&
            (fields["clearsChannel"] == "true" ||
                fields["clearsChannel"] == "false");

        private static bool HasValidAvatarArbiterResetTokenTypes(
            Dictionary<string, string> fields) =>
            IsJsonIntegerToken(fields["protocolVersion"]) &&
            IsJsonStringToken(fields["requestId"]) &&
            IsJsonIntegerToken(fields["requirementId"]) &&
            IsJsonStringToken(fields["rendererId"]) &&
            IsJsonStringToken(fields["targetOwnerToken"]) &&
            IsJsonStringToken(fields["commitToken"]) &&
            IsJsonIntegerToken(fields["retiredAccountGeneration"]) &&
            IsJsonIntegerToken(fields["retiredRendererGeneration"]) &&
            IsJsonIntegerToken(fields["targetAccountGeneration"]) &&
            IsJsonIntegerToken(fields["targetRendererGeneration"]) &&
            IsJsonStringToken(fields["payloadJson"]) &&
            IsJsonStringToken(fields["payloadSha256"]) &&
            IsJsonIntegerToken(fields["deadlineEpochMs"]);

        private static bool AreJsonNumberTokens(
            Dictionary<string, string> fields,
            HashSet<string> names)
        {
            foreach (string name in names)
            {
                if (!fields.TryGetValue(name, out string value) ||
                    !IsJsonNumberToken(value))
                {
                    return false;
                }
            }
            return true;
        }

        private static bool IsJsonStringToken(string json)
        {
            int index = 0;
            return !string.IsNullOrEmpty(json) &&
                TrySkipJsonString(json, ref index) &&
                index == json.Length;
        }

        private static bool IsJsonNumberToken(string json)
        {
            int index = 0;
            return !string.IsNullOrEmpty(json) &&
                TrySkipJsonNumber(json, ref index) &&
                index == json.Length;
        }

        private static bool IsJsonIntegerToken(string json) =>
            IsJsonNumberToken(json) &&
            json.IndexOf('.') < 0 &&
            json.IndexOf('e') < 0 &&
            json.IndexOf('E') < 0;

        private static bool IsJsonNumberArray(string json, int maximumLength)
        {
            if (string.IsNullOrEmpty(json)) return false;
            int index = 0;
            if (json[index] != '[') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            int count = 0;
            while (index < json.Length && json[index] != ']')
            {
                if (!TrySkipJsonNumber(json, ref index)) return false;
                count++;
                if (count > maximumLength) return false;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] == ']') break;
                if (json[index] != ',') return false;
                index++;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] == ']') return false;
            }
            if (index >= json.Length || json[index] != ']') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            return count > 0 && index == json.Length;
        }

        private static bool HasExactJsonObjectFields(
            string json,
            HashSet<string> expectedFields,
            out Dictionary<string, string> fields)
        {
            fields = new Dictionary<string, string>(StringComparer.Ordinal);
            if (string.IsNullOrEmpty(json) ||
                json.Length > MaximumAvatarArbiterPayloadChars)
            {
                return false;
            }
            int index = 0;
            if (!TryReadJsonObject(json, ref index, 0, out fields))
            {
                return false;
            }
            SkipJsonWhitespace(json, ref index);
            return index == json.Length &&
                expectedFields.SetEquals(fields.Keys);
        }

        private static bool TryReadJsonObject(
            string json,
            ref int index,
            int depth,
            out Dictionary<string, string> fields)
        {
            fields = new Dictionary<string, string>(StringComparer.Ordinal);
            if (depth > 32 || index >= json.Length || json[index] != '{')
            {
                return false;
            }
            index++;
            SkipJsonWhitespace(json, ref index);
            if (index < json.Length && json[index] == '}')
            {
                index++;
                return true;
            }
            while (index < json.Length)
            {
                if (!TryReadLiteralJsonKey(json, ref index, out string key) ||
                    fields.ContainsKey(key))
                {
                    return false;
                }
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] != ':')
                {
                    return false;
                }
                index++;
                SkipJsonWhitespace(json, ref index);
                int valueStart = index;
                if (!TrySkipJsonValue(json, ref index, depth + 1))
                {
                    return false;
                }
                fields.Add(key, json.Substring(valueStart, index - valueStart));
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length) return false;
                if (json[index] == '}')
                {
                    index++;
                    return true;
                }
                if (json[index] != ',') return false;
                index++;
                SkipJsonWhitespace(json, ref index);
            }
            return false;
        }

        private static bool TryReadLiteralJsonKey(
            string json,
            ref int index,
            out string key)
        {
            key = string.Empty;
            if (index >= json.Length || json[index] != '"') return false;
            index++;
            int start = index;
            while (index < json.Length)
            {
                char character = json[index++];
                if (character == '"')
                {
                    key = json.Substring(start, index - start - 1);
                    return key.Length > 0;
                }
                // Protocol field names are literal ASCII. Reject escapes so
                // alternate encodings can never alias an allowlisted field.
                if (character == '\\' || character < 0x20 || character > 0x7e)
                {
                    return false;
                }
            }
            return false;
        }

        private static bool TrySkipJsonValue(
            string json,
            ref int index,
            int depth)
        {
            if (depth > 32 || index >= json.Length) return false;
            switch (json[index])
            {
                case '{':
                    return TryReadJsonObject(json, ref index, depth, out _);
                case '[':
                    return TrySkipJsonArray(json, ref index, depth);
                case '"':
                    return TrySkipJsonString(json, ref index);
                case 't':
                    return TryConsumeJsonLiteral(json, ref index, "true");
                case 'f':
                    return TryConsumeJsonLiteral(json, ref index, "false");
                case 'n':
                    return TryConsumeJsonLiteral(json, ref index, "null");
                default:
                    return TrySkipJsonNumber(json, ref index);
            }
        }

        private static bool TrySkipJsonArray(
            string json,
            ref int index,
            int depth)
        {
            if (index >= json.Length || json[index] != '[') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            if (index < json.Length && json[index] == ']')
            {
                index++;
                return true;
            }
            while (index < json.Length)
            {
                if (!TrySkipJsonValue(json, ref index, depth + 1)) return false;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length) return false;
                if (json[index] == ']')
                {
                    index++;
                    return true;
                }
                if (json[index] != ',') return false;
                index++;
                SkipJsonWhitespace(json, ref index);
            }
            return false;
        }

        private static bool TrySkipJsonString(string json, ref int index)
        {
            if (index >= json.Length || json[index] != '"') return false;
            index++;
            while (index < json.Length)
            {
                char character = json[index++];
                if (character == '"') return true;
                if (character < 0x20) return false;
                if (character != '\\') continue;
                if (index >= json.Length) return false;
                char escape = json[index++];
                if (escape == '"' || escape == '\\' || escape == '/' ||
                    escape == 'b' || escape == 'f' || escape == 'n' ||
                    escape == 'r' || escape == 't')
                {
                    continue;
                }
                if (escape != 'u' || index + 4 > json.Length) return false;
                for (int offset = 0; offset < 4; offset++)
                {
                    if (!IsHexDigit(json[index + offset])) return false;
                }
                index += 4;
            }
            return false;
        }

        private static bool TrySkipJsonNumber(string json, ref int index)
        {
            int start = index;
            if (index < json.Length && json[index] == '-') index++;
            if (index >= json.Length) return false;
            if (json[index] == '0')
            {
                index++;
            }
            else if (json[index] >= '1' && json[index] <= '9')
            {
                while (index < json.Length &&
                    json[index] >= '0' && json[index] <= '9')
                {
                    index++;
                }
            }
            else
            {
                return false;
            }
            if (index < json.Length && json[index] == '.')
            {
                index++;
                int fractionStart = index;
                while (index < json.Length &&
                    json[index] >= '0' && json[index] <= '9')
                {
                    index++;
                }
                if (index == fractionStart) return false;
            }
            if (index < json.Length &&
                (json[index] == 'e' || json[index] == 'E'))
            {
                index++;
                if (index < json.Length &&
                    (json[index] == '+' || json[index] == '-'))
                {
                    index++;
                }
                int exponentStart = index;
                while (index < json.Length &&
                    json[index] >= '0' && json[index] <= '9')
                {
                    index++;
                }
                if (index == exponentStart) return false;
            }
            return index > start;
        }

        private static bool TryConsumeJsonLiteral(
            string json,
            ref int index,
            string literal)
        {
            if (index + literal.Length > json.Length) return false;
            for (int offset = 0; offset < literal.Length; offset++)
            {
                if (json[index + offset] != literal[offset]) return false;
            }
            index += literal.Length;
            return true;
        }

        private static void SkipJsonWhitespace(string json, ref int index)
        {
            while (index < json.Length)
            {
                char character = json[index];
                if (character != ' ' && character != '\t' &&
                    character != '\r' && character != '\n')
                {
                    return;
                }
                index++;
            }
        }

        private static bool IsHexDigit(char character) =>
            (character >= '0' && character <= '9') ||
            (character >= 'a' && character <= 'f') ||
            (character >= 'A' && character <= 'F');

        private static bool IsValidArbiterExpression(
            AvatarExpressionCommand expression)
        {
            if (expression == null || expression.mouthOpen != 0f) return false;
            return IsFiniteUnit(expression.happy) &&
                IsFiniteUnit(expression.sad) &&
                IsFiniteUnit(expression.angry) &&
                IsFiniteUnit(expression.surprised) &&
                IsFiniteUnit(expression.love) &&
                IsFiniteUnit(expression.relaxed) &&
                IsFiniteUnit(expression.thinking) &&
                IsFiniteUnit(expression.tired) &&
                IsFiniteUnit(expression.mouthSmile) &&
                IsFiniteUnit(expression.eyeOpen) &&
                IsFiniteUnit(expression.browConcern);
        }

        private static bool IsValidArbiterGaze(GazeCommand gaze)
        {
            if (gaze == null) return false;
            return IsFiniteUnitAxis(gaze.eyeX) &&
                IsFiniteUnitAxis(gaze.eyeY) &&
                IsFiniteUnitAxis(gaze.headX) &&
                IsFiniteUnitAxis(gaze.headY) &&
                IsFiniteUnitAxis(gaze.headRoll) &&
                IsFiniteUnitAxis(gaze.upperBodyX);
        }

        private static bool IsFiniteUnit(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value) &&
            value >= 0f && value <= 1f;

        private static bool IsFiniteUnitAxis(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value) &&
            value >= -1f && value <= 1f;

        private static bool IsBoundedIdentifier(string value, int maximumLength)
        {
            if (string.IsNullOrEmpty(value) || value.Length > maximumLength)
            {
                return false;
            }
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (!char.IsLetterOrDigit(character) &&
                    character != '_' && character != '-' &&
                    character != '.' && character != ':')
                {
                    return false;
                }
            }
            return true;
        }

        private static bool IsOpaqueToken(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 43) return false;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (!char.IsLetterOrDigit(character) &&
                    character != '_' && character != '-')
                {
                    return false;
                }
            }
            return true;
        }

        private static bool IsLowerHex(string value, int length)
        {
            if (string.IsNullOrEmpty(value) || value.Length != length) return false;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (!((character >= '0' && character <= '9') ||
                      (character >= 'a' && character <= 'f')))
                {
                    return false;
                }
            }
            return true;
        }

        private static string Sha256Hex(string value)
        {
            using SHA256 algorithm = SHA256.Create();
            byte[] digest = algorithm.ComputeHash(Encoding.UTF8.GetBytes(value));
            var output = new StringBuilder(digest.Length * 2);
            for (int index = 0; index < digest.Length; index++)
            {
                output.Append(digest[index].ToString("x2"));
            }
            return output.ToString();
        }

        private static bool FixedTokenEquals(string left, string right)
        {
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }
            int difference = 0;
            for (int index = 0; index < left.Length; index++)
            {
                difference |= left[index] ^ right[index];
            }
            return difference == 0;
        }

        private static long UtcEpochMilliseconds() =>
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        private static void NotifyAvatarArbiterCommandResult(
            AvatarArbiterCommand command,
            bool ok,
            string code)
        {
            if (command == null || !IsBoundedIdentifier(command.requestId, 96))
            {
                return;
            }
            NotifyCommandResult(JsonUtility.ToJson(new AvatarArbiterCommandResult
            {
                protocolVersion = AvatarArbiterProtocolVersion,
                requestId = command.requestId,
                method = "avatarArbiterCommand",
                ok = ok,
                code = ok ? string.Empty : code,
                ticket = command.ticket,
                rendererId = command.rendererId,
                ownerToken = command.ownerToken,
                commitToken = command.commitToken,
                accountGeneration = command.accountGeneration,
                rendererGeneration = command.rendererGeneration,
                channel = command.channel,
                fingerprint = command.fingerprint,
                payloadSha256 = command.payloadSha256,
                deadlineEpochMs = command.deadlineEpochMs,
                clearsChannel = command.clearsChannel,
            }));
        }

        private static void NotifyAvatarArbiterResetResult(
            AvatarArbiterReset command,
            bool ok,
            string code)
        {
            if (command == null || !IsBoundedIdentifier(command.requestId, 96))
            {
                return;
            }
            NotifyCommandResult(JsonUtility.ToJson(new AvatarArbiterResetResult
            {
                protocolVersion = AvatarArbiterProtocolVersion,
                requestId = command.requestId,
                method = "avatarArbiterReset",
                ok = ok,
                code = ok ? string.Empty : code,
                requirementId = command.requirementId,
                rendererId = command.rendererId,
                targetOwnerToken = command.targetOwnerToken,
                commitToken = command.commitToken,
                retiredAccountGeneration = command.retiredAccountGeneration,
                retiredRendererGeneration = command.retiredRendererGeneration,
                targetAccountGeneration = command.targetAccountGeneration,
                targetRendererGeneration = command.targetRendererGeneration,
                payloadSha256 = command.payloadSha256,
                deadlineEpochMs = command.deadlineEpochMs,
            }));
        }

        private static void NotifyCommandResult(string payload)
        {
            if (string.IsNullOrWhiteSpace(payload))
            {
                return;
            }
#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
            MaasoUnityAvatarCommandResult(payload);
#elif UNITY_ANDROID && !UNITY_EDITOR
            using var unityPlayer = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
            using AndroidJavaObject activity = unityPlayer.GetStatic<AndroidJavaObject>("currentActivity");
            activity?.Call("emitUnityAvatarCommandResult", payload);
#elif UNITY_STANDALONE_OSX && !UNITY_EDITOR
            DesktopUnitySidecarBridge.ReportAvatarCommandResult(payload);
#elif UNITY_STANDALONE_WIN && !UNITY_EDITOR
            WindowsUnityAvatarMessageBridge.ReportAvatarCommandResult(payload);
#else
            Debug.Log($"[UnityAvatar] command result {payload}");
#endif
        }

        private void SetPhoneInteraction(AvatarPhoneCommand command)
        {
            // Composer activity is conversational, not a cancellation of the
            // task which owns the desk. Keep its hands and return transition
            // until the host explicitly ends that task session.
            bool taskOwnsFurniture = furniturePose.Active &&
                (furniturePose.WorkSessionId != null || hostBackgroundWorkEnding || furniturePose.IsReturningFromWork);
            if (!localVisibility.Visible || avatarLeasedToWorld || presenceTransition?.OwnsPresentation == true ||
                (taskOwnsFurniture && command?.phase != "none"))
            {
                NotifyCommandResult(JsonUtility.ToJson(new AvatarPhoneResult
                {
                    requestId = command?.requestId, interactionId = command?.interactionId,
                    phase = command?.phase, ok = false, code = "presentation_busy",
                }));
                return;
            }
            phoneInteraction ??= new AvatarPhoneInteractionController(result =>
                NotifyCommandResult(JsonUtility.ToJson(result)));
            phoneInteraction.Execute(command, avatarRoot, Time.realtimeSinceStartup,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }

        private void TransitionLoginDoorway(LoginDoorwayCommand command)
        {
            WorldCameraDirector worldCamera = FindFirstObjectByType<WorldCameraDirector>();
            FrontFullBodyCamera view = FindFramingCamera();
            bool canPresent = localVisibility.Visible && !avatarLeasedToWorld &&
                presenceTransition?.OwnsPresentation != true &&
                (worldCamera == null || !worldCamera.isActiveAndEnabled || worldCamera.Phase == WorldCameraPhase.Home) &&
                view != null && view.GetComponent<Camera>()?.isActiveAndEnabled == true;
            doorwayTransition ??= new LoginDoorwayTransitionController(result =>
            {
                if (Application.isPlaying && isActiveAndEnabled)
                {
                    doorwayFrameReceipts.Add(result);
                    StartCoroutine(ReportDoorwayAfterFrame(result, doorwayRendererGeneration));
                }
                else NotifyCommandResult(JsonUtility.ToJson(result));
            });
            var map = FindFirstObjectByType<PersistentWorldMapController>();
            LoginDoorwayRig rig = command?.phase == "prepare" && canPresent ? LoginDoorwayRig.Ensure(map) : null;
            doorwayTransition.Execute(command, view, rig, canPresent,
                Time.realtimeSinceStartup, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            if (doorwayTransition.OwnsCamera) CancelHostBackgroundWork();
        }

        private System.Collections.IEnumerator ReportDoorwayAfterFrame(LoginDoorwayResult result, int generation)
        {
            yield return new WaitForEndOfFrame();
            if (!doorwayFrameReceipts.Remove(result)) yield break;
            if (generation != doorwayRendererGeneration)
            { result.ok = false; result.code = "renderer_replaced"; }
            NotifyCommandResult(JsonUtility.ToJson(result));
        }

        private void CancelLoginDoorway(string reason)
        {
            bool preserveHostWork = reason == "avatar_hidden" && HostBackgroundWorkOwnsPose();
            if (!preserveHostWork)
            {
                CancelHostBackgroundWork();
                furniturePose.Reset();
            }
            recentDesignedIdleStates.Clear();
            doorwayRendererGeneration++;
            doorwayTransition?.CancelForReset(reason);
            foreach (LoginDoorwayResult receipt in doorwayFrameReceipts)
            { receipt.ok = false; receipt.code = reason; NotifyCommandResult(JsonUtility.ToJson(receipt)); }
            doorwayFrameReceipts.Clear();
        }

        private void TransitionPresence(AvatarPresenceCommand command)
        {
            if (doorwayTransition?.OwnsCamera == true)
            {
                // Delayed opportunistic Home cleanup cannot steal a newer
                // doorway camera. Fresh handoff and fail-closed hide keep priority.
                if (command == null || command.doNotInterrupt || command.sequence <= 0 ||
                    command.expiresAtMs <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() ||
                    (command.phase != "prepare" && command.phase != "exit" && command.phase != "holdHidden"))
                {
                    NotifyCommandResult(JsonUtility.ToJson(new AvatarPresenceResult
                    {
                        requestId = command?.requestId, transitionId = command?.transitionId,
                        phase = command?.phase, ok = false, code = "doorway_busy",
                    }));
                    return;
                }
                CancelLoginDoorway("presence_takeover");
            }
            if (avatarLeasedToWorld)
            {
                NotifyCommandResult(JsonUtility.ToJson(new AvatarPresenceResult
                {
                    requestId = command?.requestId, transitionId = command?.transitionId,
                    phase = command?.phase, ok = false,
                    code = "world_busy",
                }));
                return;
            }
            presenceTransition ??= new AvatarPresenceTransitionController(result =>
            {
                if (Application.isPlaying && isActiveAndEnabled)
                {
                    presenceFrameReceipts.Add(result);
                    StartCoroutine(ReportPresenceAfterFrame(result, presenceRendererGeneration));
                }
                else NotifyCommandResult(JsonUtility.ToJson(result));
            });
            phoneInteraction?.Reset("presence_transition");
            CancelTemporaryTurn();
            bodyPoseTransitionActive = false;
            presenceTransition.Execute(command, avatarRoot, FindFramingCamera(),
                TryStartPresenceWalk,
                () => { actionPoseHoldUntil = 0f; TryStartDesignedIdle(designedIdleStateName); },
                Time.realtimeSinceStartup, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            if (presenceTransition.OwnsPresentation) CancelHostBackgroundWork();
        }

        private bool TryStartPresenceWalk()
        {
            if (animator == null || !TryFindAnimatorState("standard_walk", out int layer, out int stateHash))
                return false;
            designedIdleActive = false;
            activeDesignedIdleStateName = string.Empty;
            // Presence is a fresh arrival/departure, not a continuation of an
            // outgoing walking clip or its blend to idle. Start its own stride.
            WorldLocomotionPresentation.ApplyDefaultWalkingAnimationSpeed(animator);
            animator.CrossFadeInFixedTime(stateHash, .12f, layer, 0f);
            return true;
        }

        public void ReleaseStartupPresenceForScene(string requestedFraming = null)
        {
            if (presenceTransition?.ReleaseForScene(requestedFraming) != true) return;
            presenceRendererGeneration++;
            FailPresenceFrameReceipts("scene_takeover");
        }

        public bool PrepareHomeOwnerForAgentSpace()
        {
            CancelLoginDoorway("agent_space_takeover");
            ReleaseStartupPresenceForScene();
            EnsureAvatar();
            if (avatarRoot == null || !localVisibility.Visible || presenceTransition?.OwnsPresentation == true)
                return false;
            localVisibility.Apply(avatarRoot, false);
            avatarRoot.gameObject.SetActive(true);
            return true;
        }

        private System.Collections.IEnumerator ReportPresenceAfterFrame(AvatarPresenceResult result, int generation)
        {
            // The hidden/revealed pose must reach the render frame before the
            // account coordinator can commit departure or reveal a desktop host.
            yield return new WaitForEndOfFrame();
            if (!presenceFrameReceipts.Remove(result)) yield break;
            if (generation != presenceRendererGeneration)
            {
                result.ok = false;
                result.code = "renderer_reset";
            }
            NotifyCommandResult(JsonUtility.ToJson(result));
        }

        private void FailPresenceFrameReceipts(string reason)
        {
            foreach (AvatarPresenceResult result in presenceFrameReceipts)
            {
                result.ok = false;
                result.code = reason;
                NotifyCommandResult(JsonUtility.ToJson(result));
            }
            presenceFrameReceipts.Clear();
        }

        private void LoadAvatar(AvatarLoadCommand command)
        {
            string requestId = command?.requestId?.Trim() ?? string.Empty;
            string modelUrl = command?.modelUrl?.Trim() ?? string.Empty;
            CancelReviewedAvatarLoad();
            RetiredOfficialAvatarResources.PurgeLegacyCache();
            InvalidateHostBackgroundWorkModel(clearPending: true);
            pendingHostBackgroundWorkLoadRequestId = requestId;
            if (string.Equals(modelUrl, "unity://masso/avatar_agent", StringComparison.OrdinalIgnoreCase))
            {
                bool restored = RestoreBundledAvatar();
                NotifyAvatarLoadResult(
                    requestId,
                    restored,
                    restored ? string.Empty : "bundled_unavailable",
                    restored ? string.Empty : "Bundled avatar is unavailable.",
                    false,
                    string.Empty);
                return;
            }

            if (RetiredOfficialAvatarResources.IsRetiredDescriptor(command?.config?.modelKey, modelUrl))
            {
                NotifyAvatarLoadResult(requestId, false, "avatar_model_retired", "This official avatar is no longer available.", false, string.Empty);
                return;
            }

            string expectedSha256 = command?.config?.approvedAssetSha256?.Trim() ?? string.Empty;
            string prefabName = command?.config?.assetName?.Trim() ?? string.Empty;
            string assetFormat = Normalize(command?.config?.assetFormat);
            long expectedAssetBytes = command?.config?.approvedAssetBytes ?? 0L;
            bool isVrm = assetFormat == "vrm" || assetFormat == "vrm_1_0";
            if (!IsApprovedRemoteAvatarDescriptor(
                    modelUrl,
                    expectedSha256,
                    prefabName,
                    isVrm))
            {
                Debug.LogWarning("[UnityAvatar] rejected unapproved remote avatar descriptor");
                NotifyAvatarLoadResult(
                    requestId,
                    false,
                    "invalid_descriptor",
                    "Remote avatar descriptor is invalid.",
                    false,
                    string.Empty);
                return;
            }

            int generation = reviewedAvatarLoadGeneration;
            reviewedAvatarLoadRequestId = requestId;

            reviewedAvatarLoad = StartCoroutine(isVrm
                ? LoadReviewedVrmAvatar(
                    generation,
                    requestId,
                    modelUrl,
                    expectedSha256,
                    expectedAssetBytes)
                : LoadReviewedAvatarBundle(
                    generation,
                    requestId,
                    modelUrl,
                    expectedSha256,
                    expectedAssetBytes,
                    prefabName));
        }

        private IEnumerator LoadReviewedAvatarBundle(
            int generation,
            string requestId,
            string modelUrl,
            string expectedSha256,
            long expectedAssetBytes,
            string prefabName)
        {
            string normalizedSha256 = expectedSha256.ToLowerInvariant();
            string cacheDirectory = Path.Combine(
                Application.persistentDataPath,
                "MaasoAvatarBundles");
            string cachePath = Path.Combine(
                cacheDirectory,
                normalizedSha256 + ".bundle");
            bool cacheHit = IsValidAvatarBundleFile(
                cachePath,
                expectedAssetBytes,
                normalizedSha256,
                out _);
            if (!cacheHit)
            {
                DeleteFileIfExists(cachePath);
                Directory.CreateDirectory(cacheDirectory);
                string temporaryPath = Path.Combine(
                    cacheDirectory,
                    normalizedSha256 + "." + generation + ".tmp");
                DeleteFileIfExists(temporaryPath);

                using (UnityWebRequest request = UnityWebRequest.Get(modelUrl))
                {
                    var fileHandler = new DownloadHandlerFile(temporaryPath, true);
                    fileHandler.removeFileOnAbort = true;
                    request.downloadHandler = fileHandler;
                    yield return request.SendWebRequest();
                    if (generation != reviewedAvatarLoadGeneration)
                    {
                        DeleteFileIfExists(temporaryPath);
                        yield break;
                    }

                    if (request.result != UnityWebRequest.Result.Success)
                    {
                        DeleteFileIfExists(temporaryPath);
                        Debug.LogWarning(
                            $"[UnityAvatar] reviewed avatar download failed: {request.error}");
                        FinishAvatarLoad(
                            generation,
                            requestId,
                            false,
                            "download_failed",
                            "Avatar bundle download failed.",
                            false,
                            normalizedSha256);
                        yield break;
                    }
                }

                if (!IsValidAvatarBundleFile(
                        temporaryPath,
                        expectedAssetBytes,
                        normalizedSha256,
                        out string validationCode))
                {
                    DeleteFileIfExists(temporaryPath);
                    Debug.LogWarning(
                        "[UnityAvatar] reviewed avatar bundle failed integrity validation: " +
                        validationCode);
                    FinishAvatarLoad(
                        generation,
                        requestId,
                        false,
                        validationCode,
                        validationCode == "size_mismatch"
                            ? "Avatar bundle size mismatch."
                            : "Avatar bundle checksum mismatch.",
                        false,
                        normalizedSha256);
                    yield break;
                }

                try
                {
                    if (File.Exists(cachePath))
                    {
                        DeleteFileIfExists(cachePath);
                    }
                    File.Move(temporaryPath, cachePath);
                }
                catch (Exception error)
                {
                    DeleteFileIfExists(temporaryPath);
                    Debug.LogWarning(
                        "[UnityAvatar] reviewed avatar cache promotion failed: " +
                        error.Message);
                    FinishAvatarLoad(
                        generation,
                        requestId,
                        false,
                        "cache_write_failed",
                        "Avatar bundle could not be cached.",
                        false,
                        normalizedSha256);
                    yield break;
                }
            }

            AssetBundleCreateRequest bundleRequest = AssetBundle.LoadFromFileAsync(cachePath);
            yield return bundleRequest;
            AssetBundle bundle = bundleRequest.assetBundle;
            if (generation != reviewedAvatarLoadGeneration)
            {
                bundle?.Unload(false);
                yield break;
            }
            if (bundle == null)
            {
                DeleteFileIfExists(cachePath);
                Debug.LogWarning("[UnityAvatar] reviewed avatar bundle could not be loaded");
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "bundle_load_failed",
                    "Avatar bundle could not be loaded.",
                    cacheHit,
                    normalizedSha256);
                yield break;
            }

            AssetBundleRequest prefabRequest = bundle.LoadAssetAsync<GameObject>(prefabName);
            yield return prefabRequest;
            GameObject prefab = prefabRequest.asset as GameObject;
            if (generation != reviewedAvatarLoadGeneration)
            {
                bundle.Unload(false);
                yield break;
            }

            if (prefab == null)
            {
                bundle.Unload(false);
                Debug.LogWarning(
                    "[UnityAvatar] reviewed avatar bundle does not contain the approved prefab");
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "prefab_missing",
                    "Approved avatar prefab is missing from the bundle.",
                    cacheHit,
                    normalizedSha256);
                yield break;
            }

            Animator prefabAnimator = prefab.GetComponentInChildren<Animator>(true);
            if (prefabAnimator == null ||
                prefabAnimator.avatar == null ||
                !prefabAnimator.avatar.isHuman ||
                !HasRenderableAvatarMesh(prefab))
            {
                bundle.Unload(false);
                Debug.LogWarning(
                    "[UnityAvatar] reviewed avatar bundle does not contain a usable Humanoid prefab");
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "prefab_invalid",
                    "Approved avatar prefab is not a renderable Humanoid.",
                    cacheHit,
                    normalizedSha256);
                yield break;
            }

            try
            {
                AvatarCapabilityProfile capabilityProfile =
                    ActivateAvatarReplacement(
                        prefab,
                        bundle,
                        "reviewed avatar bundle",
                        out bool capabilityBlocked);
                if (capabilityBlocked)
                {
                    bundle.Unload(false);
                    FinishAvatarLoad(
                        generation,
                        requestId,
                        false,
                        "capability_incompatible",
                        "Avatar capability checks found blocking issues.",
                        cacheHit,
                        normalizedSha256,
                        capabilityProfile);
                    yield break;
                }
                FinishAvatarLoad(
                    generation,
                    requestId,
                    true,
                    string.Empty,
                    string.Empty,
                    cacheHit,
                    normalizedSha256,
                    capabilityProfile);
            }
            catch (Exception error)
            {
                bundle.Unload(false);
                Debug.LogWarning(
                    "[UnityAvatar] reviewed avatar activation failed: " +
                    error.Message);
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "activation_failed",
                    "Avatar activation failed.",
                    cacheHit,
                    normalizedSha256);
            }
        }

        private AvatarCapabilityProfile ActivateAvatarReplacement(
            GameObject prefab,
            AssetBundle bundle,
            string sourceLabel,
            out bool capabilityBlocked)
        {
            Transform reference = avatarRoot ?? bundledAvatarRoot;
            Transform parent = reference == null ? null : reference.parent;
            GameObject replacement = Instantiate(prefab, parent, false);
            AvatarCapabilityProfile capabilityProfile =
                AvatarCapabilityProbe.ProbeCandidate(replacement);
            capabilityBlocked = AvatarCapabilityProbe.BlocksActivation(
                capabilityProfile);
            if (capabilityBlocked)
            {
                Destroy(replacement);
                return capabilityProfile;
            }

            try
            {
                ActivateLoadedAvatarReplacement(
                    replacement,
                    bundle,
                    null,
                    reference,
                    sourceLabel);
                return capabilityProfile;
            }
            catch
            {
                Destroy(replacement);
                throw;
            }
        }

        private IEnumerator LoadReviewedVrmAvatar(
            int generation,
            string requestId,
            string modelUrl,
            string expectedSha256,
            long expectedAssetBytes)
        {
            string normalizedSha256 = expectedSha256.ToLowerInvariant();
            string cacheDirectory = Path.Combine(
                Application.persistentDataPath,
                "MaasoVrmAvatars");
            string cachePath = Path.Combine(
                cacheDirectory,
                normalizedSha256 + ".vrm");
            bool cacheHit = IsValidAvatarBundleFile(
                cachePath,
                expectedAssetBytes,
                normalizedSha256,
                out _);
            if (!cacheHit)
            {
                DeleteFileIfExists(cachePath);
                Directory.CreateDirectory(cacheDirectory);
                string temporaryPath = Path.Combine(
                    cacheDirectory,
                    normalizedSha256 + "." + generation + ".tmp");
                DeleteFileIfExists(temporaryPath);

                using (UnityWebRequest request = UnityWebRequest.Get(modelUrl))
                {
                    var fileHandler = new DownloadHandlerFile(temporaryPath, true);
                    fileHandler.removeFileOnAbort = true;
                    request.downloadHandler = fileHandler;
                    yield return request.SendWebRequest();
                    if (generation != reviewedAvatarLoadGeneration)
                    {
                        DeleteFileIfExists(temporaryPath);
                        yield break;
                    }
                    if (request.result != UnityWebRequest.Result.Success)
                    {
                        DeleteFileIfExists(temporaryPath);
                        Debug.LogWarning(
                            $"[UnityAvatar] VRM download failed: {request.error}");
                        FinishAvatarLoad(
                            generation,
                            requestId,
                            false,
                            "download_failed",
                            "VRM model download failed.",
                            false,
                            normalizedSha256);
                        yield break;
                    }
                }

                if (!IsValidAvatarBundleFile(
                        temporaryPath,
                        expectedAssetBytes,
                        normalizedSha256,
                        out string validationCode))
                {
                    DeleteFileIfExists(temporaryPath);
                    FinishAvatarLoad(
                        generation,
                        requestId,
                        false,
                        validationCode,
                        validationCode == "size_mismatch"
                            ? "VRM model size mismatch."
                            : "VRM model checksum mismatch.",
                        false,
                        normalizedSha256);
                    yield break;
                }

                try
                {
                    DeleteFileIfExists(cachePath);
                    File.Move(temporaryPath, cachePath);
                }
                catch (Exception error)
                {
                    DeleteFileIfExists(temporaryPath);
                    Debug.LogWarning(
                        "[UnityAvatar] VRM cache promotion failed: " +
                        error.Message);
                    FinishAvatarLoad(
                        generation,
                        requestId,
                        false,
                        "cache_write_failed",
                        "VRM model could not be cached.",
                        false,
                        normalizedSha256);
                    yield break;
                }
            }

            var loadTask = MaasoVrmLoader.LoadVrm10Async(cachePath);
            while (!loadTask.IsCompleted)
            {
                if (generation != reviewedAvatarLoadGeneration)
                {
                    yield break;
                }
                yield return null;
            }

            if (generation != reviewedAvatarLoadGeneration)
            {
                if (loadTask.Status == System.Threading.Tasks.TaskStatus.RanToCompletion &&
                    loadTask.Result != null)
                {
                    Destroy(loadTask.Result.gameObject);
                }
                yield break;
            }
            if (loadTask.IsFaulted || loadTask.IsCanceled || loadTask.Result == null)
            {
                string detail = loadTask.Exception?.GetBaseException().Message ??
                    "VRM importer returned no model.";
                Debug.LogWarning("[UnityAvatar] VRM import failed: " + detail);
                DeleteFileIfExists(cachePath);
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "vrm_load_failed",
                    "VRM 1.0 model could not be loaded.",
                    cacheHit,
                    normalizedSha256);
                yield break;
            }

            Vrm10Instance vrm = loadTask.Result;
            Animator vrmAnimator = vrm.GetComponentInChildren<Animator>(true);
            if (vrmAnimator == null || vrmAnimator.avatar == null ||
                !vrmAnimator.avatar.isHuman || !HasRenderableAvatarMesh(vrm.gameObject))
            {
                Destroy(vrm.gameObject);
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "vrm_invalid",
                    "VRM model is not a renderable Humanoid.",
                    cacheHit,
                    normalizedSha256);
                yield break;
            }

            AvatarCapabilityProfile capabilityProfile =
                AvatarCapabilityProbe.Probe(vrm.gameObject, vrm);
            if (AvatarCapabilityProbe.BlocksActivation(capabilityProfile))
            {
                Destroy(vrm.gameObject);
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "capability_incompatible",
                    "Avatar capability checks found blocking issues.",
                    cacheHit,
                    normalizedSha256,
                    capabilityProfile);
                yield break;
            }

            try
            {
                Transform reference = avatarRoot ?? bundledAvatarRoot;
                ActivateLoadedAvatarReplacement(
                    vrm.gameObject,
                    null,
                    vrm,
                    reference,
                    "reviewed VRM model");
                FinishAvatarLoad(
                    generation,
                    requestId,
                    true,
                    string.Empty,
                    string.Empty,
                    cacheHit,
                    normalizedSha256,
                    capabilityProfile);
            }
            catch (Exception error)
            {
                Destroy(vrm.gameObject);
                Debug.LogWarning(
                    "[UnityAvatar] VRM activation failed: " + error.Message);
                FinishAvatarLoad(
                    generation,
                    requestId,
                    false,
                    "activation_failed",
                    "VRM model activation failed.",
                    cacheHit,
                    normalizedSha256);
            }
        }

        private void ActivateLoadedAvatarReplacement(
            GameObject replacement,
            AssetBundle bundle,
            Vrm10Instance vrm,
            Transform reference,
            string sourceLabel)
        {
            agentSpace?.CancelForReset();
            GameObject sourceModel = replacement;
            replacement = CreateSourceAvatarPresentationRoot(sourceModel);
            Transform parent = reference == null ? null : reference.parent;
            replacement.transform.SetParent(parent, false);
            if (reference != null)
            {
                replacement.transform.localPosition = reference.localPosition;
                replacement.transform.localRotation = reference.localRotation;
                replacement.transform.localScale = reference.localScale;
            }

            Animator replacementAnimator =
                replacement.GetComponentInChildren<Animator>(true);
            Animator referenceAnimator =
                reference?.GetComponentInChildren<Animator>(true);
            if (replacementAnimator != null &&
                replacementAnimator.runtimeAnimatorController == null &&
                referenceAnimator?.runtimeAnimatorController != null)
            {
                replacementAnimator.runtimeAnimatorController =
                    referenceAnimator.runtimeAnimatorController;
            }

            Transform previousRoot = avatarRoot;
            GameObject previousReviewed = reviewedAvatarInstance;
            AssetBundle previousBundle = reviewedAvatarBundle;
            Vrm10Instance previousVrm = reviewedVrmInstance;
            try
            {
                BindAvatarRoot(replacement.transform);
                reviewedAvatarInstance = replacement;
                reviewedAvatarBundle = bundle;
                reviewedVrmInstance = vrm;
            }
            catch
            {
                reviewedAvatarInstance = previousReviewed;
                reviewedAvatarBundle = previousBundle;
                reviewedVrmInstance = previousVrm;
                try
                {
                    if (previousRoot != null)
                    {
                        BindAvatarRoot(previousRoot);
                    }
                    else
                    {
                        avatarRoot = null;
                    }
                }
                catch (Exception restoreError)
                {
                    avatarRoot = previousRoot;
                    Debug.LogError(
                        "[UnityAvatar] failed to restore the previous Avatar after " +
                        "candidate activation failed: " + restoreError.Message);
                }
                if (replacement != sourceModel) Destroy(replacement);
                throw;
            }

            if (previousRoot == bundledAvatarRoot && bundledAvatarRoot != null)
            {
                bundledAvatarRoot.gameObject.SetActive(false);
            }
            else if (previousReviewed != null)
            {
                Destroy(previousReviewed);
            }

            previousBundle?.Unload(false);
            ApplyExpression();
            Debug.Log("[UnityAvatar] activated " + sourceLabel);
        }

        private static GameObject CreateSourceAvatarPresentationRoot(GameObject model)
        {
            var source = model.GetComponentInChildren<AvatarHumanoidSourceIdlePose>(true);
            if (source == null || !source.IsCaptured) return model;
            Animator owner = model.GetComponentInChildren<Animator>(true);
            Transform left = owner?.GetBoneTransform(HumanBodyBones.LeftUpperArm);
            Transform right = owner?.GetBoneTransform(HumanBodyBones.RightUpperArm);
            Transform hips = owner?.GetBoneTransform(HumanBodyBones.Hips);
            Transform head = owner?.GetBoneTransform(HumanBodyBones.Head);
            if (left == null || right == null || hips == null || head == null)
                throw new InvalidOperationException("Source avatar has no complete facing reference.");

            // Home, arrival and room locomotion own a logical +Z heading. The
            // authored Matt rig faces -Z. Keep that difference on one visual
            // parent, outside the original Animator and its source-bone paths.
            Quaternion correction = WorldAvatarFacing.ResolveCorrection(
                model.transform.InverseTransformPoint(left.position),
                model.transform.InverseTransformPoint(right.position),
                model.transform.InverseTransformPoint(hips.position),
                model.transform.InverseTransformPoint(head.position));
            var presentation = new GameObject(model.name + "_Presentation");
            presentation.layer = model.layer;
            model.transform.SetParent(presentation.transform, false);
            // The previous activation replaced the model root TRS with the
            // host slot. The new outer root keeps that same host ownership.
            model.transform.localPosition = Vector3.zero;
            model.transform.localRotation = correction;
            model.transform.localScale = Vector3.one;
            presentation.AddComponent<AvatarSourcePresentationFacing>().Initialize(
                model.transform, owner, source.NativeIdleClip, correction);
            return presentation;
        }

        private bool RestoreBundledAvatar()
        {
            agentSpace?.CancelForReset();
            if (reviewedAvatarInstance != null)
            {
                Destroy(reviewedAvatarInstance);
                reviewedAvatarInstance = null;
            }
            reviewedVrmInstance = null;
            reviewedAvatarBundle?.Unload(false);
            reviewedAvatarBundle = null;

            if (bundledAvatarRoot == null)
            {
                EnsureAvatar();
                bundledAvatarRoot = avatarRoot;
            }
            if (bundledAvatarRoot == null)
            {
                Debug.LogWarning("[UnityAvatar] bundled avatar is unavailable for fallback");
                return false;
            }

            bundledAvatarRoot.gameObject.SetActive(true);
            BindAvatarRoot(bundledAvatarRoot);
            ApplyExpression();
            return true;
        }

        private void CancelReviewedAvatarLoad()
        {
            reviewedAvatarLoadGeneration++;
            if (reviewedAvatarLoad != null)
            {
                StopCoroutine(reviewedAvatarLoad);
                reviewedAvatarLoad = null;
            }

            string requestId = reviewedAvatarLoadRequestId;
            reviewedAvatarLoadRequestId = null;
            NotifyAvatarLoadResult(
                requestId,
                false,
                "superseded",
                "Avatar load was superseded by a newer selection.",
                false,
                string.Empty);
        }

        private void FinishAvatarLoad(
            int generation,
            string requestId,
            bool ok,
            string code,
            string message,
            bool cacheHit,
            string assetSha256,
            AvatarCapabilityProfile capabilityProfile = null)
        {
            if (generation != reviewedAvatarLoadGeneration)
            {
                return;
            }

            reviewedAvatarLoad = null;
            reviewedAvatarLoadRequestId = null;
            NotifyAvatarLoadResult(
                requestId,
                ok,
                code,
                message,
                cacheHit,
                assetSha256,
                capabilityProfile);
        }

        private void NotifyAvatarLoadResult(
            string requestId,
            bool ok,
            string code,
            string message,
            bool cacheHit,
            string assetSha256,
            AvatarCapabilityProfile capabilityProfile = null)
        {
            if (string.IsNullOrWhiteSpace(requestId))
            {
                return;
            }
            if (pendingHostBackgroundWorkLoadRequestId == requestId.Trim())
            {
                if (ok && isActiveAndEnabled) hostBackgroundWorkLoadRequestId = requestId.Trim();
                pendingHostBackgroundWorkLoadRequestId = null;
            }

            NotifyCommandResult(SerializeAvatarLoadResult(
                requestId.Trim(),
                ok,
                code ?? string.Empty,
                message ?? string.Empty,
                cacheHit,
                assetSha256 ?? string.Empty,
                capabilityProfile));
        }

        private static string SerializeAvatarLoadResult(
            string requestId,
            bool ok,
            string code,
            string message,
            bool cacheHit,
            string assetSha256,
            AvatarCapabilityProfile capabilityProfile)
        {
            if (capabilityProfile == null)
            {
                // JsonUtility materializes null nested serializable classes as
                // an empty object. Omitting the field keeps bundled-avatar
                // results from becoming an invalid schemaVersion=0 profile.
                return JsonUtility.ToJson(
                    new AvatarLoadResultWithoutCapabilityProfile
                    {
                        requestId = requestId,
                        method = "loadAvatar",
                        ok = ok,
                        code = code,
                        message = message,
                        cacheHit = cacheHit,
                        assetSha256 = assetSha256,
                    });
            }

            return JsonUtility.ToJson(
                new AvatarLoadResult
                {
                    requestId = requestId,
                    method = "loadAvatar",
                    ok = ok,
                    code = code,
                    message = message,
                    cacheHit = cacheHit,
                    assetSha256 = assetSha256,
                    capabilityProfile = capabilityProfile,
                });
        }

        [Serializable] private sealed class BundledMattIdentity
        {
            public string key, modelUrl, assetName, sha256;
            public int version;
        }
        private static BundledMattIdentity ReadMattIdentity()
        {
            TextAsset document = Resources.Load<TextAsset>("MattIdentity");
            if (document == null) return null;
            try { return JsonUtility.FromJson<BundledMattIdentity>(document.text); }
            catch (Exception) { return null; }
        }
        public static bool IsBundledMattDescriptor(string key, string url, string assetName, string sha256, int version)
        {
            // Retained for callers compiled against the old bridge contract.
            // No identity can enable a retired resource in this build.
            return false;
        }
        public bool TryLeaseActiveAvatarForWorld(Transform worldParent)
        {
            ReleaseStartupPresenceForScene();
            if (presenceTransition?.OwnsPresentation == true) return false;
            EnsureAvatar();
            if (avatarRoot == null ||
                worldParent == null ||
                avatarRoot == transform ||
                worldParent == avatarRoot ||
                worldParent.IsChildOf(avatarRoot))
            {
                return false;
            }

            if (avatarLeasedToWorld)
            {
                return avatarLeaseWorldParent == worldParent;
            }

            CancelHostBackgroundWork();
            CancelTemporaryTurn();
            avatarLeaseHomeParent = avatarRoot.parent;
            phoneInteraction?.Reset("world_lease");
            avatarLeaseHomeLocalPosition = avatarRoot.localPosition;
            avatarLeaseHomeLocalRotation = avatarRoot.localRotation;
            avatarLeaseHomeLocalScale = avatarRoot.localScale;
            avatarLeaseWorldParent = worldParent;
            avatarLeasedToWorld = true;
            AttachAvatarToWorldParent(avatarRoot);
            SuppressWorldAnimatorRootMotion();
            return true;
        }

        public void RestoreActiveAvatarFromWorld(Transform homeAnchor)
        {
            EnsureAvatar();
            if (!avatarLeasedToWorld || avatarRoot == null)
            {
                return;
            }

            SetWorldLocomotion(false);
            CancelTemporaryTurn();
            Transform restoredAvatar = avatarRoot;
            restoredAvatar.SetParent(avatarLeaseHomeParent, false);
            restoredAvatar.localScale = avatarLeaseHomeLocalScale;
            if (homeAnchor != null)
            {
                restoredAvatar.SetPositionAndRotation(
                    homeAnchor.position,
                    homeAnchor.rotation);
            }
            else
            {
                restoredAvatar.localPosition = avatarLeaseHomeLocalPosition;
                restoredAvatar.localRotation = avatarLeaseHomeLocalRotation;
            }

            RestoreWorldAnimatorRootMotion();
            avatarLeasedToWorld = false;
            avatarLeaseWorldParent = null;
            avatarLeaseHomeParent = null;
            if (WorldAvatarGrounding.TryGround(
                    restoredAvatar,
                    PersistentWorldMapController.GroundY,
                    out _))
            {
                RebaseActiveAvatarRootPose();
            }
            localVisibility.Apply(avatarRoot, presenceTransition?.IsHidden == true);
        }

        // The personal-room floor route has already delivered the grounded,
        // front-facing Home actor. Release hierarchy ownership without sampling
        // a new idle foot height or changing that last rendered projection.
        public bool RestoreActiveAvatarFromPersonalRoom(Transform homeAnchor)
        {
            if(!avatarLeasedToWorld || avatarRoot==null || avatarLeaseWorldParent==null ||
                homeAnchor==null || presenceTransition?.OwnsPresentation==true ||
                avatarRoot.parent!=avatarLeaseWorldParent)return false;
            Vector3 planar=avatarRoot.position-homeAnchor.position;planar.y=0;
            if(planar.sqrMagnitude>.0001f || Quaternion.Angle(avatarRoot.rotation,homeAnchor.rotation)>.15f)
                return false;
            SetWorldLocomotion(false);CancelTemporaryTurn();
            Transform restored=avatarRoot;
            Vector3 position=restored.position;Quaternion rotation=restored.rotation;
            restored.SetParent(avatarLeaseHomeParent,true);
            RestoreWorldAnimatorRootMotionContinuously();
            restored.SetPositionAndRotation(position,rotation);
            avatarLeasedToWorld=false;avatarLeaseWorldParent=null;avatarLeaseHomeParent=null;
            RebaseActiveAvatarRootPose();
            localVisibility.Apply(restored,presenceTransition?.IsHidden==true);
            return true;
        }

        public void RebaseActiveAvatarRootPose()
        {
            CancelTemporaryTurn();
            EnsureAvatar();
            if (avatarRoot == null)
            {
                return;
            }

            baseRootPosition = avatarRoot.localPosition;
            baseRootRotation = avatarRoot.localRotation;
            baseRootScale = avatarRoot.localScale;
            hasBaseRootPose = true;
            bodyPoseTransitionActive = false;
        }

        public void SetWorldLocomotion(bool active)
        {
            EnsureAvatar();
            WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(animator, active);
            if (worldLocomotionActive == active)
            {
                return;
            }

            worldLocomotionActive = active;
            if (active)
            {
                ReleaseAmbientBodyPerformance();
                upperBodyInertia.Reset();
                designedIdleActive = false;
                activeDesignedIdleStateName = string.Empty;
                if (animator != null && TryFindAnimatorState("standard_walk", out int layer, out int stateHash))
                {
                    // A fresh walk can interrupt its own pending blend to idle.
                    // NegativeInfinity's implicit time offset can retain that
                    // outgoing state instead of starting the requested stride.
                    // This branch only runs on false -> true; held targets keep
                    // the current walk and its phase without another CrossFade.
                    animator.CrossFadeInFixedTime(stateHash, .12f, layer, 0f);
                }
                else
                {
                    TryPlayAnimatorState("walking");
                }
                return;
            }

            if (!TryStartDesignedIdle(designedIdleStateName))
            {
                TryStartDesignedIdle("idle");
            }
        }

        private void BindAvatarRoot(Transform root)
        {
            pupilDynamics.Dispose();
            ResetSpeechPerformance();
            humanoidSourceIdle?.Reset();
            humanoidSourceIdle = null;
            activeArmDeformation = null;
            InvalidateHostBackgroundWorkModel();
            agentSpace?.CancelForReset();
            recentDesignedIdleStates.Clear();
            phoneInteraction?.Reset("model_replaced");
            presenceRendererGeneration++;
            FailPresenceFrameReceipts("model_replaced");
            presenceTransition?.CancelForReset("model_replaced");
            CancelLoginDoorway("model_replaced");
            CancelTemporaryTurn();
            ClearGaze(immediate: true);
            ResetExpressionTransition();
            autoBlinkWeight = 0f;
            blinkStartedAt = -1f;
            nextBlinkAt = -1f;
            StopLipSync();
            facialCalibration.Clear();
            RestoreVrmUpdateOrder();
            bool resumeWorldLocomotion = worldLocomotionActive;
            worldLocomotionActive = false;
            RestoreWorldAnimatorRootMotion();
            avatarRoot = root;
            activeVrmInstance = ResolveVrmInstance(root);
            ConfigureVrmUpdateOrder();
            if (activeVrmInstance != null)
            {
                activeVrmInstance.LookAtTarget = null;
                activeVrmInstance.LookAtTargetType =
                    VRM10ObjectLookAt.LookAtTargetTypes.YawPitchValue;
                activeVrmInstance.Runtime.LookAt.SetYawPitchManually(0f, 0f);
            }
            vrmJawOwnership.Bind(activeVrmInstance);
            // Runtime is already initialized above for the active model's
            // look-at/face binding. Contact probes only use this captured rig.
            furniturePose.SynchronizeContactPose=AvatarVrmContactPoseSampler.Capture(
                activeVrmInstance!=null?activeVrmInstance.Runtime:null,avatarRoot);
            AvatarSkinningQuality.Apply(avatarRoot);
            KeepRuntimeSkinnedMeshesVisible(avatarRoot);
            if (avatarLeasedToWorld && avatarRoot != null)
            {
                AttachAvatarToWorldParent(avatarRoot);
            }
            faceRenderer = null;
            animator = null;
            bones.Clear();
            baseRotations.Clear();
            basePositions.Clear();
            appliedGazeBoneStates.Clear();
            hasBaseRootPose = false;
            bodyPoseTransitionActive = false;
            EnsureAvatar();
            normalizedArmPose.Bind(activeVrmInstance,
                activeVrmInstance != null ? activeVrmInstance.Runtime : null);
            humanoidFaceRest = activeVrmInstance == null && avatarRoot != null ? avatarRoot.GetComponentInChildren<AvatarHumanoidFaceRestPose>(true) : null;
            humanoidFaceRest?.ConfigureImportedHinge();
            humanoidSourceIdle = activeVrmInstance == null && avatarRoot != null
                ? avatarRoot.GetComponentInChildren<AvatarHumanoidSourceIdlePose>(true) : null;
            humanoidSourceIdle?.Bind(animator);
            facialCalibration.Bind(avatarRoot, activeVrmInstance,
                activeVrmInstance != null && activeVrmInstance == bundledVrmInstance,
                humanoidFaceRest, humanoidSourceIdle);
            BindPupilDynamics();
            // Joy's portable skin retains segmented Rigify deform bones. The
            // source arm-twist constraints are model deformation, independent
            // of the current task or high-level animation owner.
            if (activeVrmInstance != null && avatarRoot != null)
            {
                Transform deformRoot = activeVrmInstance.transform;
                activeArmDeformation = deformRoot.GetComponent<AvatarRigifyArmDeformation>() ??
                    deformRoot.gameObject.AddComponent<AvatarRigifyArmDeformation>();
                activeArmDeformation.Bind(deformRoot);
                // Restore the source model's local elbow surface smoothing.
                // The helper validates the exact mesh before adding owned GPU
                // corrective shapes; all existing expression indices survive.
                var elbowCorrectives = deformRoot.GetComponent<AvatarJoyElbowCorrectives>() ??
                    deformRoot.gameObject.AddComponent<AvatarJoyElbowCorrectives>();
                elbowCorrectives.Bind(deformRoot);
            }
            conversationalMicroMotion.Bind(animator);
            freeGestureCollision.Bind(activeVrmInstance != null ? activeVrmInstance.transform : avatarRoot, animator);
            speechGestures.SetProfile(activeVrmInstance != null ? "realistic" : "restrained");
            if (avatarLeasedToWorld)
            {
                SuppressWorldAnimatorRootMotion();
            }
            SetWorldLocomotion(resumeWorldLocomotion);
            FrontFullBodyCamera framing = FindFramingCamera();
            if (framing != null)
            {
                framing.TargetRoot = avatarRoot;
            }
            ApplyExpression();
            localVisibility.Apply(avatarRoot, presenceTransition?.IsHidden == true);
            if (avatarLeasedToWorld && avatarLeaseWorldParent != null)
            {
                WorldOwnerAvatarLease lease =
                    avatarLeaseWorldParent.GetComponent<WorldOwnerAvatarLease>();
                if (lease != null && !lease.IsWorldVisible)
                {
                    // LateUpdate also refreshes hidden leases, but a newly bound
                    // model must inherit the mask before the next rendered frame.
                    lease.SetWorldVisible(false);
                }
            }
        }

        private void BindPupilDynamics() => pupilDynamics.Bind(avatarRoot,
            activeVrmInstance != null && activeVrmInstance == bundledVrmInstance);

        private void AdvancePupilDynamics(float now)
        {
            if (hostBackgroundWorkPaused || !localVisibility.Visible)
            {
                pupilDynamics.Reset();
                return;
            }
            pupilDynamics.Advance(now, AvatarPupilDynamics.ResolveArousal(
                currentExpression.surprised, currentExpression.angry, currentExpression.happy,
                currentExpression.love, currentExpression.thinking, currentExpression.sad,
                currentExpression.browConcern, currentExpression.relaxed, currentExpression.tired));
        }

        private void ConfigureVrmUpdateOrder()
        {
            if (activeVrmInstance == null || !isActiveAndEnabled ||
                updateOrderVrmInstance == activeVrmInstance)
            {
                return;
            }
            RestoreVrmUpdateOrder();
            updateOrderVrmInstance = activeVrmInstance;
            previousVrmUpdateType = activeVrmInstance.UpdateType;
            activeVrmInstance.UpdateType = Vrm10Instance.UpdateTypes.LateUpdate;
        }

        private void RestoreVrmUpdateOrder()
        {
            if (updateOrderVrmInstance != null &&
                updateOrderVrmInstance.UpdateType == Vrm10Instance.UpdateTypes.LateUpdate)
            {
                updateOrderVrmInstance.UpdateType = previousVrmUpdateType;
            }
            updateOrderVrmInstance = null;
        }

        private Vrm10Instance ResolveVrmInstance(Transform root)
        {
            if (root == null)
            {
                return null;
            }
            if (root == bundledAvatarRoot && bundledVrmInstance != null)
            {
                return bundledVrmInstance;
            }
            return root.GetComponentInChildren<Vrm10Instance>(true);
        }

        private static void KeepRuntimeSkinnedMeshesVisible(Transform root)
        {
            if (root == null)
            {
                return;
            }

            SkinnedMeshRenderer[] renderers =
                root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            for (int index = 0; index < renderers.Length; index++)
            {
                if (renderers[index] != null)
                {
                    renderers[index].updateWhenOffscreen = true;
                }
            }
        }

        private void AttachAvatarToWorldParent(Transform root)
        {
            if (root == null || avatarLeaseWorldParent == null)
            {
                return;
            }
            root.SetParent(avatarLeaseWorldParent, false);
            root.localPosition = Vector3.zero;
            root.localRotation = Quaternion.identity;
            root.localScale = avatarLeaseHomeLocalScale;
            WorldAvatarFacing.AlignToRootForward(root);
        }

        private void SuppressWorldAnimatorRootMotion()
        {
            Animator activeAnimator =
                avatarRoot?.GetComponentInChildren<Animator>(true);
            if (activeAnimator == null)
            {
                return;
            }
            if (avatarLeaseAnimator != activeAnimator)
            {
                RestoreWorldAnimatorRootMotion();
                avatarLeaseAnimator = activeAnimator;
                avatarLeaseAnimatorApplyRootMotion =
                    activeAnimator.applyRootMotion;
            }
            activeAnimator.applyRootMotion = false;
        }

        private void RestoreWorldAnimatorRootMotion()
        {
            if (avatarLeaseAnimator != null)
            {
                avatarLeaseAnimator.applyRootMotion =
                    avatarLeaseAnimatorApplyRootMotion;
            }
            avatarLeaseAnimator = null;
            avatarLeaseAnimatorApplyRootMotion = false;
        }

        private void RestoreWorldAnimatorRootMotionContinuously()
        {
            Animator current=avatarLeaseAnimator;
            if(current==null || current.applyRootMotion==avatarLeaseAnimatorApplyRootMotion)
            { avatarLeaseAnimator=null;avatarLeaseAnimatorApplyRootMotion=false;return; }
            // Changing applyRootMotion reinitializes Unity's Animator. The
            // return owns only root travel, so retain the sampled live body
            // and every layer's clock while restoring its original setting.
            var poses=new List<(Transform bone,Vector3 position,Quaternion rotation,Vector3 scale)>();
            foreach(var bone in avatarRoot.GetComponentsInChildren<Transform>(true))
                poses.Add((bone,bone.localPosition,bone.localRotation,bone.localScale));
            var states=new AnimatorStateInfo[current.layerCount];
            for(int layer=0;layer<states.Length;layer++)states[layer]=current.GetCurrentAnimatorStateInfo(layer);
            current.applyRootMotion=avatarLeaseAnimatorApplyRootMotion;
            for(int layer=0;layer<states.Length;layer++)
                if(states[layer].fullPathHash!=0)current.Play(states[layer].fullPathHash,layer,states[layer].normalizedTime);
            current.Update(0);
            foreach(var pose in poses)if(pose.bone!=null)
            {pose.bone.localPosition=pose.position;pose.bone.localRotation=pose.rotation;pose.bone.localScale=pose.scale;}
            avatarLeaseAnimator=null;avatarLeaseAnimatorApplyRootMotion=false;
        }

        private void StabilizeWorldLeaseRootPose()
        {
            if (!avatarLeasedToWorld ||
                avatarRoot == null ||
                !hasBaseRootPose)
            {
                return;
            }

            avatarRoot.localPosition = baseRootPosition;
            avatarRoot.localRotation = baseRootRotation;
            avatarRoot.localScale = baseRootScale;
        }

        private static bool HasRenderableAvatarMesh(GameObject prefab)
        {
            if (prefab == null)
            {
                return false;
            }

            SkinnedMeshRenderer[] skinnedRenderers =
                prefab.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            for (int i = 0; i < skinnedRenderers.Length; i++)
            {
                Mesh mesh = skinnedRenderers[i]?.sharedMesh;
                if (mesh != null && mesh.vertexCount > 0)
                {
                    return true;
                }
            }

            MeshFilter[] meshFilters = prefab.GetComponentsInChildren<MeshFilter>(true);
            for (int i = 0; i < meshFilters.Length; i++)
            {
                Mesh mesh = meshFilters[i]?.sharedMesh;
                if (mesh != null && mesh.vertexCount > 0)
                {
                    return true;
                }
            }

            return false;
        }

        private static bool IsValidAvatarBundleFile(
            string path,
            long expectedAssetBytes,
            string expectedSha256,
            out string errorCode)
        {
            errorCode = string.Empty;
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                errorCode = "cache_missing";
                return false;
            }

            try
            {
                var info = new FileInfo(path);
                if (info.Length <= 0 ||
                    (expectedAssetBytes > 0 && info.Length != expectedAssetBytes))
                {
                    errorCode = "size_mismatch";
                    return false;
                }

                using FileStream stream = File.OpenRead(path);
                using SHA256 sha256 = SHA256.Create();
                byte[] actual = sha256.ComputeHash(stream);
                string actualHex = BitConverter
                    .ToString(actual)
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
                if (!string.Equals(
                        actualHex,
                        expectedSha256,
                        StringComparison.OrdinalIgnoreCase))
                {
                    errorCode = "checksum_mismatch";
                    return false;
                }
                return true;
            }
            catch (Exception error)
            {
                Debug.LogWarning(
                    "[UnityAvatar] avatar bundle integrity check failed: " +
                    error.Message);
                errorCode = "cache_read_failed";
                return false;
            }
        }

        private static void DeleteFileIfExists(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return;
            }

            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (Exception error)
            {
                Debug.LogWarning(
                    "[UnityAvatar] could not remove avatar bundle cache file: " +
                    error.Message);
            }
        }

        private static bool IsApprovedRemoteAvatarDescriptor(
            string modelUrl,
            string expectedSha256,
            string prefabName,
            bool isVrm)
        {
            if (!Uri.TryCreate(modelUrl, UriKind.Absolute, out Uri uri) ||
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(uri.Host) ||
                string.IsNullOrWhiteSpace(expectedSha256) ||
                expectedSha256.Length != 64 ||
                (!isVrm && (string.IsNullOrWhiteSpace(prefabName) ||
                    prefabName.Contains("..", StringComparison.Ordinal))))
            {
                return false;
            }

            for (int i = 0; i < expectedSha256.Length; i++)
            {
                if (!Uri.IsHexDigit(expectedSha256[i]))
                {
                    return false;
                }
            }

            for (int i = 0; i < prefabName.Length; i++)
            {
                char character = prefabName[i];
                if (!char.IsLetterOrDigit(character) && character != '_' && character != '-' && character != '/')
                {
                    return false;
                }
            }

            return true;
        }

        private static bool Sha256Matches(byte[] bytes, string expectedSha256)
        {
            if (bytes == null || bytes.Length == 0)
            {
                return false;
            }

            using (SHA256 sha256 = SHA256.Create())
            {
                byte[] actual = sha256.ComputeHash(bytes);
                if (actual.Length * 2 != expectedSha256.Length)
                {
                    return false;
                }

                int difference = 0;
                for (int i = 0; i < actual.Length; i++)
                {
                    string hex = actual[i].ToString("x2");
                    difference |= char.ToLowerInvariant(expectedSha256[i * 2]) ^ hex[0];
                    difference |= char.ToLowerInvariant(expectedSha256[i * 2 + 1]) ^ hex[1];
                }
                return difference == 0;
            }
        }

        private void SetViewportSafeArea(ViewportSafeAreaCommand command)
        {
            FrontFullBodyCamera framing = FindFramingCamera();
            if (framing == null)
            {
                return;
            }

            framing.SetViewportSafeArea(command.Top, command.Bottom);
            Debug.Log(
                $"[UnityAvatar] applied viewportSafeArea top={command.Top:F3} bottom={command.Bottom:F3}");
        }

        private void SetFraming(FramingCommand command)
        {
            FrontFullBodyCamera framing = FindFramingCamera();
            if (framing == null)
            {
                return;
            }

            framing.SetFramingMode(command.mode);
            Debug.Log($"[UnityAvatar] applied framing mode={command.mode}");
        }

        private void SetWorldTimeOfDay(WorldTimeOfDayCommand command)
        {
            if (worldLighting == null)
            {
                worldLighting = GetComponent<UnityWorldLightingController>();
            }

            if (worldLighting == null)
            {
                worldLighting = FindFirstObjectByType<UnityWorldLightingController>();
            }

            if (worldLighting == null)
            {
                Debug.LogWarning("[UnityAvatar] world lighting controller is unavailable");
                return;
            }

            worldLighting.SetTimeOfDay(command.timeOfDay);
        }

        private AgentSpaceController EnsureAgentSpace()
        {
            agentSpace ??= GetComponent<AgentSpaceController>() ?? gameObject.AddComponent<AgentSpaceController>();
            return agentSpace;
        }


        private static FrontFullBodyCamera FindFramingCamera()
        {
            Camera mainCamera = Camera.main;
            if (mainCamera != null && mainCamera.TryGetComponent(out FrontFullBodyCamera framing))
            {
                return framing;
            }

            return FindAnyObjectByType<FrontFullBodyCamera>();
        }

        private void EnsureAvatar()
        {
            if (avatarRoot == null)
            {
                avatarRoot = FindDefaultTarget() ?? transform;
            }

            if (faceRenderer == null || FaceBlendShapeScore(faceRenderer) == 0)
            {
                faceRenderer = FindFaceRenderer(avatarRoot);
            }

            if (animator == null)
            {
                animator = avatarRoot.GetComponentInChildren<Animator>(true);
            }

            if (!hasBaseRootPose && avatarRoot != null)
            {
                baseRootPosition = avatarRoot.localPosition;
                baseRootRotation = avatarRoot.localRotation;
                baseRootScale = avatarRoot.localScale;
                hasBaseRootPose = true;
            }

            CacheBones();
        }

        private void CacheBones()
        {
            bones.Clear();
            if (avatarRoot == null)
            {
                return;
            }

            Transform[] children = avatarRoot.GetComponentsInChildren<Transform>(true);
            for (int i = 0; i < children.Length; i++)
            {
                Transform child = children[i];
                string key = Normalize(child.name);
                if (!bones.ContainsKey(key))
                {
                    bones.Add(key, child);
                }

                if (!baseRotations.ContainsKey(child))
                {
                    baseRotations.Add(child, child.localRotation);
                }

                if (!basePositions.ContainsKey(child))
                {
                    basePositions.Add(child, child.localPosition);
                }
            }
        }

        private void SetExpression(AvatarExpressionCommand expression)
        {
            float now = Time.realtimeSinceStartup;
            UpdateExpressionTransition(now);
            AvatarExpressionCommand next = BlendExpression(
                AvatarExpressionCommand.Default,
                (expression ?? AvatarExpressionCommand.Default).WithDefaults(),
                1f);
            // Speech start/stop refreshes can repeat the same affect. Reusing
            // the current target preserves its onset/release clock rather
            // than restarting a smile every time a channel is refreshed.
            if (EquivalentExpression(expressionTarget, next))
            {
                ApplyExpression();
                return;
            }
            expressionTransitionStart = currentExpression;
            expressionTarget = next;
            expressionTransitionStartedAt = now;
            expressionTransitionActive = true;
            ApplyExpression();
        }

        private static bool EquivalentExpression(AvatarExpressionCommand a, AvatarExpressionCommand b)
        {
            const float epsilon = .0001f;
            return Mathf.Abs(a.happy - b.happy) < epsilon &&
                Mathf.Abs(a.sad - b.sad) < epsilon && Mathf.Abs(a.angry - b.angry) < epsilon &&
                Mathf.Abs(a.surprised - b.surprised) < epsilon && Mathf.Abs(a.love - b.love) < epsilon &&
                Mathf.Abs(a.relaxed - b.relaxed) < epsilon && Mathf.Abs(a.thinking - b.thinking) < epsilon &&
                Mathf.Abs(a.tired - b.tired) < epsilon && Mathf.Abs(a.mouthSmile - b.mouthSmile) < epsilon &&
                Mathf.Abs(a.mouthOpen - b.mouthOpen) < epsilon && Mathf.Abs(a.eyeOpen - b.eyeOpen) < epsilon &&
                Mathf.Abs(a.browConcern - b.browConcern) < epsilon;
        }

        private void UpdateExpressionTransition(float now)
        {
            if (!expressionTransitionActive) return;
            float duration = ExpressionTransitionSeconds;
            if (facialCalibration.IsCalibrated)
            {
                float fromSmile = AvatarFacialCalibration.SmileIntent(expressionTransitionStart.happy,
                    expressionTransitionStart.mouthSmile, expressionTransitionStart.love);
                float toSmile = AvatarFacialCalibration.SmileIntent(expressionTarget.happy,
                    expressionTarget.mouthSmile, expressionTarget.love);
                if (fromSmile > 0f || toSmile > 0f)
                    duration = toSmile > fromSmile ? .38f : .65f;
                if (toSmile < fromSmile && Mathf.Max(expressionTarget.sad,
                    expressionTarget.angry, expressionTarget.browConcern) >= .3f)
                    duration = .25f;
            }
            float t = Mathf.Clamp01(
                (now - expressionTransitionStartedAt) / duration);
            currentExpression = BlendExpression(
                expressionTransitionStart,
                expressionTarget,
                Mathf.SmoothStep(0f, 1f, t));
            expressionTransitionActive = t < 1f;
            ApplyExpression();
        }

        private void ResetExpressionTransition()
        {
            currentExpression = AvatarExpressionCommand.Default;
            expressionTransitionStart = currentExpression;
            expressionTarget = currentExpression;
            expressionTransitionActive = false;
        }

        private static AvatarExpressionCommand BlendExpression(
            AvatarExpressionCommand from,
            AvatarExpressionCommand to,
            float weight)
        {
            return new AvatarExpressionCommand
            {
                happy = Mathf.Lerp(from.happy, Clamp01(to.happy), weight),
                sad = Mathf.Lerp(from.sad, Clamp01(to.sad), weight),
                angry = Mathf.Lerp(from.angry, Clamp01(to.angry), weight),
                surprised = Mathf.Lerp(from.surprised, Clamp01(to.surprised), weight),
                love = Mathf.Lerp(from.love, Clamp01(to.love), weight),
                relaxed = Mathf.Lerp(from.relaxed, Clamp01(to.relaxed), weight),
                thinking = Mathf.Lerp(from.thinking, Clamp01(to.thinking), weight),
                tired = Mathf.Lerp(from.tired, Clamp01(to.tired), weight),
                mouthSmile = Mathf.Lerp(from.mouthSmile, Clamp01(to.mouthSmile), weight),
                mouthOpen = Mathf.Lerp(from.mouthOpen, Clamp01(to.mouthOpen), weight),
                eyeOpen = Mathf.Lerp(from.eyeOpen, Clamp01(to.eyeOpen), weight),
                browConcern = Mathf.Lerp(from.browConcern, Clamp01(to.browConcern), weight),
            };
        }

        private void SetMouthOpen(float value)
        {
            if (speechPlaybackClock.Paused && speechMouthBound)
            {
                // Existing pause consumers also emit a scalar zero after the
                // stop event. Close without erasing this paused session's track.
                lipSyncActive = false;
                mouthOpen = 0f;
                ClearMouthVisemes();
                ApplyExpression();
                return;
            }
            lipSyncActive = false;
            lipSyncUsesVisemeTimeline = false;
            lipSyncEnvelope = null;
            lipSyncVisemeCues = null;
            ClearMouthVisemes();
            mouthOpen = Clamp01(value);
            ApplyExpression();
        }

        private void StartLipSync(LipSyncCommand command)
        {
            if (command.envelope == null || command.envelope.Length == 0)
            {
                return;
            }

            lipSyncEnvelope = command.envelope;
            lipSyncVisemeCues = null;
            lipSyncVisemeCueIndex = 0;
            lipSyncUsesVisemeTimeline = false;
            lipSyncFrameRate = Mathf.Clamp(command.frameRate <= 0 ? 30 : command.frameRate, 1, 120);
            lipSyncStartedAt = Time.realtimeSinceStartup;
            lipSyncActive = true;
            speechMouthBound = speechPlaybackClock.MatchesEnvelope(lipSyncEnvelope, lipSyncFrameRate);
            ClearMouthVisemes();
            mouthOpen = ShapeLipSyncAmplitude(lipSyncEnvelope[0]);
            ApplyExpression();
        }

        private void StartVisemeTimeline(LipSyncCommand command)
        {
            lipSyncEnvelope = command.envelope;
            lipSyncVisemeCues = command.cues;
            lipSyncVisemeCueIndex = 0;
            lipSyncUsesVisemeTimeline = true;
            lipSyncFrameRate = command.frameRate;
            lipSyncStartedAt = Time.realtimeSinceStartup;
            lipSyncActive = true;
            speechMouthBound = speechPlaybackClock.MatchesEnvelope(lipSyncEnvelope, lipSyncFrameRate);
            mouthOpen = 0f;
            ApplyLipSyncFrame(0f);
        }

        private void StopLipSync()
        {
            if (speechPlaybackClock.Paused && speechMouthBound)
            {
                lipSyncActive = false;
                mouthOpen = 0f;
                ClearMouthVisemes();
                ApplyExpression();
                return;
            }
            speechMouthBound = false;
            lipSyncActive = false;
            lipSyncUsesVisemeTimeline = false;
            lipSyncEnvelope = null;
            lipSyncVisemeCues = null;
            lipSyncVisemeCueIndex = 0;
            mouthOpen = 0f;
            humanoidFaceRest?.Apply(0);
            ClearMouthVisemes();
            ApplyExpression();
        }

        private void UpdateLipSync()
        {
            if (!lipSyncActive || lipSyncEnvelope == null || lipSyncEnvelope.Length == 0)
            {
                return;
            }

            bool usePlaybackClock = speechMouthBound && speechPlaybackClock.Authoritative;
            if (speechMouthBound && (speechPlaybackClock.Paused ||
                (usePlaybackClock && !speechPlaybackClock.IsPlaying(Time.realtimeSinceStartup))))
            {
                mouthOpen = 0f;
                ClearMouthVisemes();
                ApplyExpression();
                return;
            }
            float framePosition = Mathf.Max(0f, (usePlaybackClock ?
                speechPlaybackClock.Position(Time.realtimeSinceStartup) : Time.realtimeSinceStartup - lipSyncStartedAt) * lipSyncFrameRate);
            int index = Mathf.FloorToInt(framePosition);
            if (index >= lipSyncEnvelope.Length)
            {
                StopLipSync();
                return;
            }

            if (lipSyncUsesVisemeTimeline)
            {
                ApplyLipSyncFrame(framePosition);
                return;
            }
            mouthOpen = ShapeLipSyncAmplitude(
                lipSyncEnvelope[Mathf.Max(0, index)]);
            ApplyExpression();
        }

        private void ApplyLipSyncFrame(float framePosition)
        {
            if (!lipSyncUsesVisemeTimeline ||
                lipSyncEnvelope == null ||
                lipSyncEnvelope.Length == 0 ||
                lipSyncVisemeCues == null ||
                lipSyncVisemeCues.Length == 0)
            {
                return;
            }
            int frame = Mathf.Clamp(
                Mathf.FloorToInt(framePosition),
                0,
                lipSyncEnvelope.Length - 1);
            if (lipSyncVisemeCueIndex >= lipSyncVisemeCues.Length || lipSyncVisemeCues[lipSyncVisemeCueIndex].frame > framePosition)
                lipSyncVisemeCueIndex = 0;
            while (lipSyncVisemeCueIndex + 1 < lipSyncVisemeCues.Length &&
                lipSyncVisemeCues[lipSyncVisemeCueIndex + 1].frame <= framePosition)
            {
                lipSyncVisemeCueIndex++;
            }

            ClearMouthVisemes();
            float amplitude = ShapeLipSyncAmplitude(lipSyncEnvelope[frame]);
            LipSyncVisemeCue current = lipSyncVisemeCues[lipSyncVisemeCueIndex];
            if (lipSyncVisemeCueIndex + 1 >= lipSyncVisemeCues.Length)
            {
                AddMouthVisemeWeight(current.viseme, amplitude);
                ApplyExpression();
                return;
            }

            LipSyncVisemeCue next = lipSyncVisemeCues[lipSyncVisemeCueIndex + 1];
            float segmentFrames = Mathf.Max(1f, next.frame - current.frame);
            float crossFadeFrames = Mathf.Min(LipSyncCrossFadeFrames, segmentFrames);
            float mix = Mathf.Clamp01(
                (framePosition - (next.frame - crossFadeFrames)) /
                crossFadeFrames);
            AddMouthVisemeWeight(current.viseme, amplitude * (1f - mix));
            AddMouthVisemeWeight(next.viseme, amplitude * mix);
            ApplyExpression();
        }

        private void ClearMouthVisemes()
        {
            mouthVisemePp = 0f; mouthVisemeFf = 0f;
            mouthVisemeAa = 0f;
            mouthVisemeIh = 0f;
            mouthVisemeOu = 0f;
            mouthVisemeEe = 0f;
            mouthVisemeOh = 0f;
        }

        private void AddMouthVisemeWeight(string viseme, float value)
        {
            float weight = Clamp01(value);
            switch (viseme)
            {
                case "pp": mouthVisemePp = Clamp01(mouthVisemePp + weight); break;
                case "ff": mouthVisemeFf = Clamp01(mouthVisemeFf + weight); break;
                case "aa":
                    mouthVisemeAa = Clamp01(mouthVisemeAa + weight);
                    break;
                case "ih":
                    mouthVisemeIh = Clamp01(mouthVisemeIh + weight);
                    break;
                case "ou":
                    mouthVisemeOu = Clamp01(mouthVisemeOu + weight);
                    break;
                case "ee":
                    mouthVisemeEe = Clamp01(mouthVisemeEe + weight);
                    break;
                case "oh":
                    mouthVisemeOh = Clamp01(mouthVisemeOh + weight);
                    break;
            }
        }

        private static float ShapeLipSyncAmplitude(float value)
        {
            float clamped = Clamp01(value);
            if (clamped <= LipSyncNoiseFloor) return 0f;
            float normalized =
                (clamped - LipSyncNoiseFloor) / (1f - LipSyncNoiseFloor);
            return Clamp01(
                Mathf.Pow(normalized, LipSyncAmplitudeGamma) *
                LipSyncAmplitudeGain);
        }

        private void UpdateAutoBlink()
        {
            UpdateAutoBlinkAt(Time.realtimeSinceStartup);
        }

        private void UpdateAutoBlinkAt(float now)
        {
            if (!autoBlink || (activeVrmInstance == null &&
                (faceRenderer == null || faceRenderer.sharedMesh == null)))
            {
                blinkStartedAt = -1f;
                nextBlinkAt = -1f;
                if (autoBlinkWeight > 0f)
                {
                    autoBlinkWeight = 0f;
                    ApplyExpression();
                }

                return;
            }

            if (blinkStartedAt >= 0f)
            {
                float duration = Mathf.Max(0.05f, blinkDurationSeconds);
                float elapsed = now - blinkStartedAt;
                if (elapsed >= duration)
                {
                    blinkStartedAt = -1f;
                    autoBlinkWeight = 0f;
                    ScheduleNextBlink(now);
                    ApplyExpression();
                    return;
                }

                float t = Mathf.Clamp01(elapsed / duration);
                autoBlinkWeight = t < BlinkClosingFraction
                    ? Mathf.SmoothStep(0f, 1f, t / BlinkClosingFraction)
                    : 1f - Mathf.SmoothStep(
                        0f, 1f, (t - BlinkClosingFraction) / (1f - BlinkClosingFraction));
                ApplyExpression();
                return;
            }

            if (nextBlinkAt < 0f)
            {
                ScheduleNextBlink(now);
                return;
            }

            if (now >= nextBlinkAt)
            {
                blinkStartedAt = now;
                autoBlinkWeight = 0f;
                ApplyExpression();
            }
        }

        private void ScheduleNextBlink(float now)
        {
            float jitter = blinkIntervalJitterSeconds <= 0f
                ? 0f
                : UnityEngine.Random.Range(-blinkIntervalJitterSeconds, blinkIntervalJitterSeconds);
            float interval = Mathf.Max(0.6f, blinkIntervalSeconds + jitter);
            nextBlinkAt = now + interval;
        }

        private void UpdateIdlePose()
        {
            if (conversationHintsEnabled && HostBackgroundWorkAuthorityReleased() &&
                !AnnieMotionBlocked() && !temporaryTurnActive &&
                (conversationPolicyClip != null || speechGestureAnimator.ActiveId != null)) return;
            if (worldLocomotionActive)
            {
                return;
            }

            float now = Time.realtimeSinceStartup;
            if (temporaryTurnActive && avatarRoot == null) CancelTemporaryTurn();
            if (temporaryTurnActive && temporaryTurnReturning)
            {
                if (bodyPoseTransitionActive) return;
                CancelTemporaryTurn();
            }
            if (now < actionPoseHoldUntil)
            {
                return;
            }

            // A semantic turn is a short conversational beat. Restore its
            // rotation even without an Animator, before considering idle clips.
            if (temporaryTurnActive)
            {
                temporaryTurnReturning = true;
                StartRootRotationTransition(baseRootRotation, temporaryTurnTransitionSeconds);
                return;
            }

            if (designedIdleActive && nextIdleStateAt > now)
            {
                return;
            }

            if (TryStartDesignedIdle())
            {
                return;
            }
        }

        private bool TryStartDesignedIdle()
        {
            return TryStartDesignedIdle(NextDesignedIdleStateName());
        }

        private bool TryStartDesignedIdle(string requestedStateName)
        {
            if (!preferDesignedIdle ||
                animator == null ||
                animator.runtimeAnimatorController == null)
            {
                return false;
            }

            string stateName = string.IsNullOrWhiteSpace(requestedStateName) ? "idle" : requestedStateName.Trim();
            int stateHash = Animator.StringToHash(stateName);
            for (int layer = 0; layer < animator.layerCount; layer++)
            {
                int resolvedHash = stateHash;
                if (!animator.HasState(layer, resolvedHash))
                {
                    string layerPath = $"{animator.GetLayerName(layer)}.{stateName}";
                    resolvedHash = Animator.StringToHash(layerPath);
                    if (!animator.HasState(layer, resolvedHash))
                    {
                        continue;
                    }
                }

                if (!designedIdleActive || activeDesignedIdleStateName != stateName)
                {
                    animator.CrossFadeInFixedTime(resolvedHash, 0.2f, layer, 0f);
                }

                designedIdleActive = true;
                activeDesignedIdleStateName = stateName;
                RememberDesignedIdleState(stateName);
                ScheduleNextIdleState(Time.realtimeSinceStartup);
                return true;
            }

            if (!HasDesignedIdleClip(stateName))
            {
                return false;
            }

            if (!designedIdleActive || activeDesignedIdleStateName != stateName)
            {
                try
                {
                    animator.CrossFadeInFixedTime(stateName, 0.2f);
                }
                catch (Exception error)
                {
                    if (logCommands)
                    {
                        Debug.LogWarning($"[UnityAvatar] designed idle clip fallback failed {stateName}: {error.Message}");
                    }
                }
            }

            designedIdleActive = true;
            activeDesignedIdleStateName = stateName;
            RememberDesignedIdleState(stateName);
            ScheduleNextIdleState(Time.realtimeSinceStartup);
            return true;
        }

        private string NextDesignedIdleStateName()
        {
            string mainIdle = string.IsNullOrWhiteSpace(designedIdleStateName)
                ? "idle"
                : designedIdleStateName.Trim();
            string[] variants = AvailableIdleVariantStateNames(mainIdle);
            var fresh=new List<string>();
            foreach(string candidate in variants)
            {
                if(string.Equals(candidate,activeDesignedIdleStateName,StringComparison.OrdinalIgnoreCase))continue;
                bool recent=false;foreach(string previous in recentDesignedIdleStates)
                    if(string.Equals(candidate,previous,StringComparison.OrdinalIgnoreCase)){recent=true;break;}
                if(!recent)fresh.Add(candidate);
            }
            if(fresh.Count>0)variants=fresh.ToArray();
            else if(HasDesignedIdleState(mainIdle))return mainIdle;
            // With no alternative authored resource, retain the previous safe
            // selection/fallback rather than inventing an unavailable clip.
            int variantIndex = variants.Length == 0 ? 0 : UnityEngine.Random.Range(0, variants.Length);
            return SelectWeightedIdleState(
                mainIdle,
                variants,
                mainIdleProbability,
                UnityEngine.Random.value,
                variantIndex);
        }
        private void RememberDesignedIdleState(string state)
        {
            recentDesignedIdleStates.Enqueue(state);
            while(recentDesignedIdleStates.Count>2)recentDesignedIdleStates.Dequeue();
        }

        private string[] AvailableIdleVariantStateNames(string mainIdle)
        {
            if (idleVariantStateNames == null || idleVariantStateNames.Length == 0)
            {
                return Array.Empty<string>();
            }

            var variants = new List<string>();
            for (int i = 0; i < idleVariantStateNames.Length; i++)
            {
                string stateName = idleVariantStateNames[i];
                if (string.IsNullOrWhiteSpace(stateName))
                {
                    continue;
                }

                stateName = stateName.Trim();
                if (string.Equals(stateName, mainIdle, StringComparison.OrdinalIgnoreCase) ||
                    !HasDesignedIdleState(stateName))
                {
                    continue;
                }

                variants.Add(stateName);
            }

            return variants.ToArray();
        }

        private static string SelectWeightedIdleState(
            string mainIdle,
            string[] variants,
            float mainProbability,
            float roll,
            int variantIndex)
        {
            string fallback = string.IsNullOrWhiteSpace(mainIdle) ? "idle" : mainIdle.Trim();
            if (variants == null || variants.Length == 0)
            {
                return fallback;
            }

            if (Mathf.Clamp01(roll) < Mathf.Clamp01(mainProbability))
            {
                return fallback;
            }

            int index = Mathf.Abs(variantIndex) % variants.Length;
            string variant = variants[index];
            return string.IsNullOrWhiteSpace(variant) ? fallback : variant.Trim();
        }

        private void ScheduleNextIdleState(float now)
        {
            float min = Mathf.Max(0.8f, idleStateMinSeconds);
            float max = Mathf.Max(min, idleStateMaxSeconds);
            nextIdleStateAt = now + UnityEngine.Random.Range(min, max);
        }

        private bool HasDesignedIdleState(string stateName)
        {
            if (animator == null || animator.runtimeAnimatorController == null)
            {
                return false;
            }

            int stateHash = Animator.StringToHash(stateName);
            for (int layer = 0; layer < animator.layerCount; layer++)
            {
                if (animator.HasState(layer, stateHash))
                {
                    return true;
                }

                string layerPath = $"{animator.GetLayerName(layer)}.{stateName}";
                if (animator.HasState(layer, Animator.StringToHash(layerPath)))
                {
                    return true;
                }
            }

            return HasDesignedIdleClip(stateName);
        }

        private bool HasDesignedIdleClip(string stateName)
        {
            AnimationClip[] clips = animator.runtimeAnimatorController.animationClips;
            for (int i = 0; i < clips.Length; i++)
            {
                AnimationClip clip = clips[i];
                if (clip != null && string.Equals(clip.name, stateName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private void ApplyExpression()
        {
            // Speech owns vowel amplitudes, including silent frames in a timeline.
            // VRM's expression overrides still blend emotion with those vowels.
            float closure = 1f - Mathf.Clamp01(mouthVisemePp * 2f);
            float expressionMouth = lipSyncActive || mouthOpen > 0f
                ? 0f
                : currentExpression.mouthOpen;
            if (activeVrmInstance != null)
            {
                Vrm10RuntimeExpression expression =
                    activeVrmInstance.Runtime.Expression;
                float vrmSmile = Mathf.Max(
                    currentExpression.mouthSmile,
                    currentExpression.happy * 0.8f,
                    currentExpression.love * 0.55f);
                float vrmMouth = Mathf.Max(expressionMouth, mouthOpen);
                VrmVisemeWeights vrmVisemes = ResolveVrmVisemeWeights(
                    expression.ExpressionKeys,
                    vrmMouth * closure,
                    mouthVisemeAa * closure,
                    mouthVisemeIh * closure,
                    mouthVisemeOu * closure,
                    Mathf.Max(mouthVisemeEe, mouthVisemeFf * .25f) * closure,
                    mouthVisemeOh * closure);
                float vrmBlink = Mathf.Max(
                    Clamp01(1f - currentExpression.eyeOpen),
                    autoBlinkWeight, furniturePose.IsLying ? 1f : 0f);
                float smileIntent = AvatarFacialCalibration.SmileIntent(
                    currentExpression.happy, currentExpression.mouthSmile, currentExpression.love);
                float happy = Mathf.Max(currentExpression.happy, vrmSmile);
                if (facialCalibration.IsJoy)
                {
                    happy = facialCalibration.MouthSmile(smileIntent,
                        Mathf.Max(vrmMouth, mouthVisemeAa), mouthVisemeIh, mouthVisemeOu,
                        mouthVisemeEe, mouthVisemeOh, mouthVisemePp, mouthVisemeFf);
                    // Joy's Relaxed also contains lip_smile. Use its small
                    // eyelid component through Blink, without adding the lips
                    // twice or making thinking/tired imply a smile.
                    vrmBlink = Mathf.Max(vrmBlink,
                        Mathf.Max(currentExpression.relaxed, currentExpression.thinking * .25f,
                            currentExpression.tired * .4f) * .1f,
                        facialCalibration.EyeSmile(smileIntent) * .08f);
                }
                expression.SetWeight(ExpressionKey.Happy, happy);
                expression.SetWeight(ExpressionKey.Sad, currentExpression.sad);
                expression.SetWeight(ExpressionKey.Angry, currentExpression.angry);
                expression.SetWeight(
                    ExpressionKey.Surprised,
                    facialCalibration.Surprise(currentExpression.surprised, smileIntent));
                expression.SetWeight(
                    ExpressionKey.Relaxed,
                    facialCalibration.IsJoy ? 0f : Mathf.Max(
                        currentExpression.relaxed,
                        currentExpression.thinking * 0.25f,
                        currentExpression.tired * 0.4f));
                expression.SetWeight(
                    ExpressionKey.Aa,
                    vrmVisemes.aa);
                expression.SetWeight(ExpressionKey.Ih, vrmVisemes.ih);
                expression.SetWeight(ExpressionKey.Ou, vrmVisemes.ou);
                expression.SetWeight(ExpressionKey.Ee, vrmVisemes.ee);
                expression.SetWeight(ExpressionKey.Oh, vrmVisemes.oh);
                bool hasCombinedBlink = HasVrmExpressionBindings(
                    activeVrmInstance.Vrm.Expression.Blink);
                expression.SetWeight(ExpressionKey.Blink, hasCombinedBlink ? vrmBlink : 0f);
                expression.SetWeight(ExpressionKey.BlinkLeft, hasCombinedBlink ? 0f : vrmBlink);
                expression.SetWeight(ExpressionKey.BlinkRight, hasCombinedBlink ? 0f : vrmBlink);
                facialCalibration.SetSpeech(vrmVisemes.aa, vrmVisemes.ih,
                    vrmVisemes.ou, vrmVisemes.ee, vrmVisemes.oh);
                ApplyFacialCompanions();
                return;
            }

            if (faceRenderer == null || faceRenderer.sharedMesh == null)
            {
                return;
            }

            float smileIntentNative = AvatarFacialCalibration.SmileIntent(
                currentExpression.happy, currentExpression.mouthSmile, currentExpression.love);
            float smile = facialCalibration.IsCalibrated
                ? facialCalibration.MouthSmile(smileIntentNative,
                    Mathf.Max(expressionMouth, Mathf.Max(mouthOpen, mouthVisemeAa)),
                    mouthVisemeIh, mouthVisemeOu, mouthVisemeEe, mouthVisemeOh,
                    mouthVisemePp, mouthVisemeFf)
                : Mathf.Max(currentExpression.mouthSmile, currentExpression.happy * .8f,
                    currentExpression.love * .55f);
            float mouth = Mathf.Max(expressionMouth, mouthOpen);
            float blink = Mathf.Max(Clamp01(1f - currentExpression.eyeOpen), autoBlinkWeight, furniturePose.IsLying ? 1f : 0f);
            float concern = Mathf.Max(currentExpression.browConcern, currentExpression.thinking * 0.55f, currentExpression.sad * 0.45f);

            SetBlendShapeAliasGroups(currentExpression.happy, HappyBlendShapeGroups);
            SetBlendShapeAliasGroups(currentExpression.sad, SadBlendShapeGroups);
            SetBlendShapeAliasGroups(currentExpression.angry, AngryBlendShapeGroups);
            SetBlendShapeAliasGroups(facialCalibration.Surprise(currentExpression.surprised, smileIntentNative), SurprisedBlendShapeGroups);
            SetBlendShapeAliasGroups(currentExpression.love, LoveBlendShapeGroups);
            SetBlendShapeAliasGroups(Mathf.Max(currentExpression.relaxed,
                facialCalibration.EyeSmile(smileIntentNative) * .18f), RelaxedBlendShapeGroups);
            SetBlendShapeAliasGroups(currentExpression.thinking, ThinkingBlendShapeGroups);
            SetBlendShapeAliasGroups(currentExpression.tired, TiredBlendShapeGroups);
            SetBlendShapeAliasGroups(smile, SmileBlendShapeGroups);
            SetNonVrmMouthVisemes(
                Mathf.Max(mouth, mouthVisemeAa),
                mouthVisemeIh,
                mouthVisemeOu,
                mouthVisemeEe,
                mouthVisemeOh);
            ApplyFacialCompanions();
            SetBlendShapeAliasGroups(blink, BlinkBlendShapeGroups);
            SetBlendShapeAliasGroups(concern, ConcernBlendShapeGroups);
        }

        private void ApplyFacialCompanions()
        {
            facialCalibration.ApplyCompanions(AvatarFacialCalibration.SmileIntent(
                currentExpression.happy, currentExpression.mouthSmile, currentExpression.love));
        }

        private static bool HasVrmExpressionBindings(VRM10Expression expression)
        {
            return expression != null &&
                ((expression.MorphTargetBindings?.Length ?? 0) > 0 ||
                 (expression.MaterialColorBindings?.Length ?? 0) > 0 ||
                 (expression.MaterialUVBindings?.Length ?? 0) > 0 ||
                 (expression.NodeTransformBindings?.Length ?? 0) > 0);
        }

        private static VrmVisemeWeights ResolveVrmVisemeWeights(
            IReadOnlyList<ExpressionKey> available,
            float baseMouth,
            float aa,
            float ih,
            float ou,
            float ee,
            float oh)
        {
            var resolved = new VrmVisemeWeights
            {
                aa = Mathf.Max(baseMouth, aa),
            };
            bool hasIh = ContainsExpression(available, ExpressionKey.Ih);
            bool hasOu = ContainsExpression(available, ExpressionKey.Ou);
            bool hasEe = ContainsExpression(available, ExpressionKey.Ee);
            bool hasOh = ContainsExpression(available, ExpressionKey.Oh);
            AddResolvedVrmViseme(
                ref resolved,
                ih,
                hasIh ? 1 : hasEe ? 3 : 0);
            AddResolvedVrmViseme(
                ref resolved,
                ee,
                hasEe ? 3 : hasIh ? 1 : 0);
            AddResolvedVrmViseme(
                ref resolved,
                ou,
                hasOu ? 2 : hasOh ? 4 : 0);
            AddResolvedVrmViseme(
                ref resolved,
                oh,
                hasOh ? 4 : hasOu ? 2 : 0);
            return resolved;
        }

        private static void AddResolvedVrmViseme(
            ref VrmVisemeWeights resolved,
            float value,
            int targetIndex)
        {
            float weight = Clamp01(value);
            switch (targetIndex)
            {
                case 1:
                    resolved.ih = Clamp01(resolved.ih + weight);
                    break;
                case 2:
                    resolved.ou = Clamp01(resolved.ou + weight);
                    break;
                case 3:
                    resolved.ee = Clamp01(resolved.ee + weight);
                    break;
                case 4:
                    resolved.oh = Clamp01(resolved.oh + weight);
                    break;
                default:
                    resolved.aa = Clamp01(resolved.aa + weight);
                    break;
            }
        }

        private static bool ContainsExpression(
            IReadOnlyList<ExpressionKey> available,
            ExpressionKey target)
        {
            if (available == null) return false;
            for (int index = 0; index < available.Count; index++)
            {
                if (available[index].Equals(target)) return true;
            }
            return false;
        }

        private void ApplyGaze(GazeCommand gaze)
        {
            // A newer explicit/arbiter gaze retires the old pointer owner.
            // Its later expiry must never clear that new instruction.
            RetireScreenTapAttention();
            float now = Time.realtimeSinceStartup;
            BeginGazeTransition(gaze, now, GazeTransitionSeconds);
        }

        private void BeginGazeTransition(GazeCommand gaze, float now, float duration)
        {
            UpdateGazeTransition(now);
            gazeTransitionStart = currentGaze;
            gazeTarget = (gaze ?? GazeCommand.Center).Clamped();
            gazeTransitionStartedAt = now;
            gazeTransitionDuration = duration;
            gazeTransitionActive = true;
            gazeReleasing = false;
            gazeActive = true;
        }

        private void ClearGaze(bool immediate = false)
        {
            RetireScreenTapAttention();
            if (!immediate && gazeActive)
            {
                ApplyGaze(GazeCommand.Center);
                gazeReleasing = true;
                return;
            }
            currentGaze = GazeCommand.Center;
            gazeTransitionStart = currentGaze;
            gazeTarget = currentGaze;
            gazeTransitionActive = false;
            gazeTransitionDuration = GazeTransitionSeconds;
            gazeReleasing = false;
            gazeActive = false;
            RestoreOwnedGazePose();
        }

        private void UpdateGazeTransition(float now)
        {
            if (!gazeTransitionActive) return;
            float t = Mathf.Clamp01(
                (now - gazeTransitionStartedAt) / gazeTransitionDuration);
            currentGaze = BlendGaze(
                gazeTransitionStart, gazeTarget, Mathf.SmoothStep(0f, 1f, t));
            gazeTransitionActive = t < 1f;
            if (!gazeTransitionActive && gazeReleasing)
            {
                ClearGaze(immediate: true);
            }
        }

        private static GazeCommand BlendGaze(GazeCommand from, GazeCommand to, float weight)
        {
            return new GazeCommand
            {
                eyeX = Mathf.Lerp(from.eyeX, to.eyeX, weight),
                eyeY = Mathf.Lerp(from.eyeY, to.eyeY, weight),
                headX = Mathf.Lerp(from.headX, to.headX, weight),
                headY = Mathf.Lerp(from.headY, to.headY, weight),
                headRoll = Mathf.Lerp(from.headRoll, to.headRoll, weight),
                upperBodyX = Mathf.Lerp(from.upperBodyX, to.upperBodyX, weight),
            };
        }

        private void ApplyGazePose()
        {
            float upperBodyWeight = IsBodyActionHeld()
                ? UpperBodyGazeActionWeight
                : UpperBodyGazeIdleWeight;
            ApplyGazeToBone(
                FindUpperBodyBone(),
                currentGaze.upperBodyX,
                0f,
                0f,
                UpperBodyGazeYawDegrees,
                0f,
                0f,
                upperBodyWeight);
            Transform head = animator != null && animator.isHuman
                ? animator.GetBoneTransform(HumanBodyBones.Head)
                : null;
            head ??= FindBone("head", "neck_02", "neck");
            if (activeVrmInstance != null)
            {
                ApplyAvatarSpaceGazeToBone(
                    head,
                    currentGaze.headX,
                    currentGaze.headY,
                    currentGaze.headRoll,
                    HeadGazeYawDegrees,
                    HeadGazePitchDegrees,
                    HeadGazeRollDegrees,
                    1f);
            }
            else
            {
                ApplyGazeToBone(
                    head,
                    currentGaze.headX,
                    currentGaze.headY,
                    currentGaze.headRoll,
                    HeadGazeYawDegrees,
                    HeadGazePitchDegrees,
                    HeadGazeRollDegrees,
                    1f);
            }
            Transform leftEye = FindEyeBone(true);
            Transform rightEye = FindEyeBone(false);
            if (activeVrmInstance != null)
            {
                ClearEyeBlendShapeGaze();
                ReleaseOwnedGazeDelta(leftEye);
                ReleaseOwnedGazeDelta(rightEye);
                activeVrmInstance.Runtime.LookAt.SetYawPitchManually(
                    VrmLookAtYawInput(currentGaze.eyeX),
                    VrmLookAtPitchInput(ResolveHomeEyeContactVertical(currentGaze.eyeY)));
            }
            else if (leftEye != null && rightEye != null)
            {
                ClearEyeBlendShapeGaze();
                ApplyEyeGazeToBone(
                    leftEye,
                    head,
                    currentGaze.eyeX,
                    currentGaze.eyeY);
                ApplyEyeGazeToBone(
                    rightEye,
                    head,
                    currentGaze.eyeX,
                    currentGaze.eyeY);
            }
            else
            {
                ReleaseOwnedGazeDelta(leftEye);
                ReleaseOwnedGazeDelta(rightEye);
                ApplyEyeBlendShapeGaze(currentGaze.eyeX, currentGaze.eyeY);
            }
        }

        private bool HasHomeEyeContactPresentation()
        {
            return activeVrmInstance != null && HasHomeGazePresentation();
        }

        private bool HasHomeGazePresentation()
        {
            if (avatarRoot == null || !localVisibility.Visible ||
                avatarLeasedToWorld || worldLocomotionActive ||
                phoneInteraction?.OwnsHands == true ||
                presenceTransition?.OwnsPresentation == true)
            {
                return false;
            }
            FrontFullBodyCamera framing = FindFramingCamera();
            if (framing == null || !framing.isActiveAndEnabled || framing.TargetRoot != avatarRoot)
            {
                return false;
            }
            Camera camera = framing.GetComponent<Camera>();
            // World cameras disable Home framing. A transparent desktop pet
            // camera, or Home's avatar-culled portal capture, is not Home eye contact.
            return camera != null && !camera.orthographic &&
                (camera.clearFlags == CameraClearFlags.Skybox || camera.backgroundColor.a >= .99f) &&
                (camera.cullingMask & (1 << avatarRoot.gameObject.layer)) != 0;
        }

        private float ResolveHomeEyeContactVertical(float vertical)
        {
            float clamped = ClampUnit(vertical);
            if (!HasHomeEyeContactPresentation()) return clamped;
            // Recompute from the command, never from last frame's eye rotation.
            // Explicit up/down extremes retain their full authored range.
            return clamped + HomeEyeContactVerticalBias * (1f - Mathf.Abs(clamped));
        }

        private void ApplyHomeEyeContact()
        {
            if (!HasHomeEyeContactPresentation()) return;
            activeVrmInstance.Runtime.LookAt.SetYawPitchManually(
                0f, VrmLookAtPitchInput(HomeEyeContactVerticalBias));
        }

        private float VrmLookAtYawInput(float horizontal)
        {
            VRM10ObjectLookAt lookAt = activeVrmInstance?.Vrm?.LookAt;
            float inputRange = lookAt == null
                ? 90f
                : Mathf.Max(
                    LookAtInputRange(lookAt.HorizontalInner),
                    LookAtInputRange(lookAt.HorizontalOuter));
            return ScreenHorizontalToAvatarYaw * ClampUnit(horizontal) * inputRange;
        }

        private float VrmLookAtPitchInput(float vertical)
        {
            float clamped = ClampUnit(vertical);
            VRM10ObjectLookAt lookAt = activeVrmInstance?.Vrm?.LookAt;
            CurveMapper mapper = lookAt == null
                ? null
                : clamped >= 0f
                    ? lookAt.VerticalUp
                    : lookAt.VerticalDown;
            return clamped * LookAtInputRange(mapper);
        }

        private static float LookAtInputRange(CurveMapper mapper)
        {
            float inputRange = mapper?.CurveXRangeDegree ?? 90f;
            if (float.IsNaN(inputRange) ||
                float.IsInfinity(inputRange) ||
                inputRange <= Mathf.Epsilon)
            {
                return 90f;
            }
            return Mathf.Clamp(inputRange, 1f, 90f);
        }

        private void ApplyEyeBlendShapeGaze(float horizontal, float vertical)
        {
            if (faceRenderer == null || faceRenderer.sharedMesh == null)
            {
                return;
            }

            float screenHorizontal = ClampUnit(horizontal);
            float screenVertical = ClampUnit(vertical);
            SetBlendShapeGroup(
                EyeLookLeftBlendShapes,
                Mathf.Max(0f, screenHorizontal) * 100f);
            SetBlendShapeGroup(
                EyeLookRightBlendShapes,
                Mathf.Max(0f, -screenHorizontal) * 100f);
            SetBlendShapeGroup(
                EyeLookUpBlendShapes,
                Mathf.Max(0f, screenVertical) * 100f);
            SetBlendShapeGroup(
                EyeLookDownBlendShapes,
                Mathf.Max(0f, -screenVertical) * 100f);
        }

        private void ClearEyeBlendShapeGaze()
        {
            if (faceRenderer == null || faceRenderer.sharedMesh == null)
            {
                return;
            }

            SetBlendShapeGroup(EyeLookLeftBlendShapes, 0f);
            SetBlendShapeGroup(EyeLookRightBlendShapes, 0f);
            SetBlendShapeGroup(EyeLookUpBlendShapes, 0f);
            SetBlendShapeGroup(EyeLookDownBlendShapes, 0f);
        }

        private void ApplyGazeToBone(
            Transform bone,
            float horizontal,
            float vertical,
            float roll,
            float yawDegrees,
            float pitchDegrees,
            float rollDegrees,
            float weight)
        {
            if (bone == null)
            {
                return;
            }

            Quaternion animationRotation = ReleaseOwnedGazeDelta(bone);
            float clampedWeight = Mathf.Clamp01(weight);
            float yaw = ScreenHorizontalToAvatarYaw * ClampUnit(horizontal) *
                yawDegrees * clampedWeight;
            float pitch = -ClampUnit(vertical) * pitchDegrees * clampedWeight;
            float tilt = ClampUnit(roll) * rollDegrees * clampedWeight;
            Quaternion delta = Quaternion.Euler(pitch, yaw, tilt);
            if (Quaternion.Angle(Quaternion.identity, delta) <= Mathf.Epsilon)
            {
                return;
            }

            Quaternion result = animationRotation * delta;
            bone.localRotation = result;
            appliedGazeBoneStates[bone] = new AppliedGazeBoneState
            {
                lastDelta = delta,
                lastResult = result,
            };
        }

        private void ApplyAvatarSpaceGazeToBone(
            Transform bone,
            float horizontal,
            float vertical,
            float roll,
            float yawDegrees,
            float pitchDegrees,
            float rollDegrees,
            float weight)
        {
            if (bone == null)
            {
                return;
            }

            Quaternion animationRotation = ReleaseOwnedGazeDelta(bone);
            float clampedWeight = Mathf.Clamp01(weight);
            float yaw = ScreenHorizontalToAvatarYaw * ClampUnit(horizontal) *
                yawDegrees * clampedWeight;
            float pitch = -ClampUnit(vertical) * pitchDegrees * clampedWeight;
            float tilt = ClampUnit(roll) * rollDegrees * clampedWeight;
            Quaternion avatarSpaceDelta = Quaternion.Euler(pitch, yaw, tilt);
            if (Quaternion.Angle(Quaternion.identity, avatarSpaceDelta) <= Mathf.Epsilon)
            {
                return;
            }

            Transform basis = activeVrmInstance == null
                ? avatarRoot
                : activeVrmInstance.Runtime.LookAt.LookAtOriginTransform;
            Quaternion basisRotation = basis == null
                ? Quaternion.identity
                : basis.rotation;
            Quaternion worldDelta =
                basisRotation * avatarSpaceDelta * Quaternion.Inverse(basisRotation);
            Quaternion animationWorldRotation = bone.parent == null
                ? animationRotation
                : bone.parent.rotation * animationRotation;
            Quaternion resultWorldRotation = worldDelta * animationWorldRotation;
            Quaternion result = bone.parent == null
                ? resultWorldRotation
                : Quaternion.Inverse(bone.parent.rotation) * resultWorldRotation;
            Quaternion ownedPostDelta =
                Quaternion.Inverse(animationRotation) * result;
            bone.localRotation = result;
            appliedGazeBoneStates[bone] = new AppliedGazeBoneState
            {
                lastDelta = ownedPostDelta,
                lastResult = result,
            };
        }

        private void ApplyEyeGazeToBone(
            Transform eye,
            Transform head,
            float horizontal,
            float vertical)
        {
            if (eye == null)
            {
                return;
            }

            if (head == null || eye.parent == null)
            {
                ApplyGazeToBone(
                    eye,
                    horizontal,
                    vertical,
                    0f,
                    EyeGazeYawDegrees,
                    EyeGazePitchDegrees,
                    0f,
                    1f);
                return;
            }

            Quaternion animationRotation = ReleaseOwnedGazeDelta(eye);
            float yaw = ScreenHorizontalToAvatarYaw * ClampUnit(horizontal) *
                EyeGazeYawDegrees;
            float pitch = -ClampUnit(vertical) * EyeGazePitchDegrees;
            Quaternion headDelta = Quaternion.Euler(pitch, yaw, 0f);
            if (Quaternion.Angle(Quaternion.identity, headDelta) <= Mathf.Epsilon)
            {
                return;
            }

            // Eye rigs do not share one local axis convention. The bundled
            // JunVRC eyes, for example, use local Y as their forward axis, so
            // applying yaw around local Y only rolls the eyeball. Express the
            // logical pitch/yaw in head space, convert it into the eye parent's
            // coordinate system, then store an equivalent post-delta so the
            // existing ownership/restoration protocol remains exact.
            Quaternion headInEyeParent =
                Quaternion.Inverse(eye.parent.rotation) * head.rotation;
            Quaternion parentSpaceDelta =
                headInEyeParent * headDelta * Quaternion.Inverse(headInEyeParent);
            Quaternion ownedPostDelta =
                Quaternion.Inverse(animationRotation) *
                parentSpaceDelta *
                animationRotation;
            Quaternion result = animationRotation * ownedPostDelta;
            eye.localRotation = result;
            appliedGazeBoneStates[eye] = new AppliedGazeBoneState
            {
                lastDelta = ownedPostDelta,
                lastResult = result,
            };
        }

        private Quaternion ReleaseOwnedGazeDelta(Transform bone)
        {
            if (ReferenceEquals(bone, null))
            {
                return Quaternion.identity;
            }

            if (!appliedGazeBoneStates.TryGetValue(
                    bone,
                    out AppliedGazeBoneState state))
            {
                return bone == null ? Quaternion.identity : bone.localRotation;
            }

            appliedGazeBoneStates.Remove(bone);
            if (bone == null)
            {
                return Quaternion.identity;
            }

            Quaternion current = bone.localRotation;
            if (Quaternion.Angle(current, state.lastResult) >
                GazeOwnershipAngleToleranceDegrees)
            {
                return current;
            }

            Quaternion restored = current * Quaternion.Inverse(state.lastDelta);
            bone.localRotation = restored;
            return restored;
        }

        private void RestoreOwnedGazePose()
        {
            if (activeVrmInstance != null)
            {
                activeVrmInstance.Runtime.LookAt.SetYawPitchManually(0f, 0f);
            }
            ClearEyeBlendShapeGaze();
            if (appliedGazeBoneStates.Count == 0)
            {
                return;
            }

            var trackedBones = new List<Transform>(appliedGazeBoneStates.Keys);
            for (int index = 0; index < trackedBones.Count; index++)
            {
                ReleaseOwnedGazeDelta(trackedBones[index]);
            }
            appliedGazeBoneStates.Clear();
        }

        private bool IsBodyActionHeld()
        {
            return bodyPoseTransitionActive ||
                worldLocomotionActive ||
                Time.realtimeSinceStartup < actionPoseHoldUntil;
        }

        private void PlayPrimitive(PrimitiveCommand command)
        {
            string type = Normalize(command.type);
            PrimitiveOptions options = command.options ?? PrimitiveOptions.Default;
            if (options.energy != null)
            {
                if (!ValidPerformanceStyle(options.energy, options.emotion, options.intensity) ||
                    !PerformanceBodyGestures.Contains(type)) return;
                if (IsSpeechPerformanceGesture(type))
                {
                    QueueSpeechPerformanceCue(type, options.emotion, options.energy, options.intensity,
                        ++legacyPerformanceSequence, UtcEpochMilliseconds() + Mathf.Clamp(options.durationMs, 350, 5000));
                    return;
                }
            }
            ClearSpeechPerformanceCue();
            ApplyPrimitive(type, options.Intensity);
            if (options.durationMs > 0)
            {
                HoldActionPose(options.durationMs / 1000f);
            }
        }

        private void PlayAnimationClip(AnimationClipCommand command)
        {
            ReleaseAmbientBodyPerformance();
            upperBodyInertia.RequestTransition();
            string id = Normalize(command.id);
            if (id.StartsWith(OpenAnnieMotionPlayback.Prefix, StringComparison.Ordinal))
            {
                if (AnnieMotionBlocked()) return;
                if (annieMotion.TryPlay(animator, id, Time.realtimeSinceStartup, false, command.HoldSeconds))
                    HoldActionPose();
                else
                {
                    // Imported avatars can bring their own controller. Keep
                    // their established semantic fallback when it lacks this pack.
                    string fallback = annieMotion.FallbackMotion(id);
                    if (fallback != null)
                    {
                        if (!TryPlayAnimatorState(fallback)) ApplyPrimitive(fallback, command.Intensity);
                        HoldActionPose(command.HoldSeconds);
                    }
                }
                return;
            }
            if (TryPlayAnimatorState(id))
            {
                HoldActionPose(command.HoldSeconds);
                return;
            }

            if (id.Contains("goodbye") || id.Contains("wave"))
            {
                ApplyPrimitive("wave", command.Intensity);
            }
            else if (id.Contains("thinking") || id.Contains("think"))
            {
                ApplyPrimitive("think", command.Intensity);
            }
            else if (id.Contains("jump"))
            {
                ApplyPrimitive("jump", command.Intensity);
            }
        }

        private void ReactToScreenTap(ScreenTapCommand command)
        {
            // Screen attention must not take over a task's authored camera,
            // furniture, phone, entrance or room-locomotion presentation.
            if (ScreenTapAttentionBlocked()) return;
            float x = Mathf.Clamp01(command.X);
            float y = Mathf.Clamp01(command.Y);
            float holdSeconds = Mathf.Clamp(command.HoldSeconds, 0f,
                ScreenTapMaximumAttentionSeconds - ScreenTapReturnSeconds);
            bool home = HasHomeGazePresentation();
            ApplyGaze(new GazeCommand
            {
                eyeX = Mathf.Lerp(-0.65f, 0.65f, x),
                eyeY = Mathf.Lerp(0.3f, -0.25f, y),
                headX = Mathf.Lerp(-0.45f, 0.45f, x),
                headY = Mathf.Lerp(0.2f, -0.18f, y),
            });
            // Home taps are a brief additive look, not a whole-body idle clip
            // whose head turn could continue after the pointer gaze is gone.
            if (home)
            {
                screenTapGazeReleaseAt = gazeTransitionStartedAt + holdSeconds;
                screenTapGazeReturnBy = gazeTransitionStartedAt + holdSeconds + ScreenTapReturnSeconds;
                screenTapGazeRequiresHome = true;
                return;
            }

            string clipId = SelectScreenTapClipId(x);
            if (TryPlayAnimatorState(clipId))
            {
                HoldActionPose(holdSeconds);
                return;
            }

            HoldActionPose(holdSeconds);
            ApplyPrimitive(x >= 0.5f ? "look_away" : "listen", 0.55f);
        }

        private bool ScreenTapAttentionBlocked() => hostBackgroundWorkPaused ||
            !localVisibility.Visible || avatarLeasedToWorld || worldLocomotionActive ||
            bodyPoseTransitionActive || temporaryTurnActive || furniturePose.Active ||
            phoneInteraction?.OwnsHands == true || presenceTransition?.OwnsPresentation == true ||
            doorwayTransition?.OwnsCamera == true || agentSpace?.IsReturningHome == true;

        private void AdvanceScreenTapAttention(float now)
        {
            if (screenTapGazeReturnBy < 0f) return;
            if (ScreenTapAttentionBlocked() ||
                (screenTapGazeRequiresHome && !HasHomeGazePresentation()) ||
                now >= screenTapGazeReturnBy)
            {
                ClearGaze(immediate: true);
                return;
            }
            if (screenTapGazeReleaseAt < 0f || now < screenTapGazeReleaseAt) return;
            screenTapGazeReleaseAt = -1f;
            BeginGazeTransition(GazeCommand.Center, now,
                Mathf.Min(ScreenTapReturnSeconds, screenTapGazeReturnBy - now));
            gazeReleasing = true;
        }

        private void RetireScreenTapAttention()
        {
            screenTapGazeReleaseAt = screenTapGazeReturnBy = -1f;
            screenTapGazeRequiresHome = false;
        }

        private static string SelectScreenTapClipId(float normalizedX)
        {
            return Mathf.Clamp01(normalizedX) >= 0.66f
                ? "idle_turn_right_1"
                : "idle_look_around_1";
        }

        private void SetHandTarget(HandTargetCommand command)
        {
            ApplyPrimitive(Normalize(command.target), command.Intensity);
        }

        private void SetBodyPose(BodyPoseCommand command)
        {
            // Explicit poses retain their persistent semantics and supersede
            // both the outward and returning phases of a semantic turn.
            CancelTemporaryTurn();
            annieMotion.Stop();
            if (avatarRoot == null)
            {
                return;
            }

            Vector3 targetPosition = BodyPosePosition(command);
            Quaternion targetRotation = BodyPoseRotation(command);
            Vector3 targetScale = BodyPoseScale(command);
            float duration = Mathf.Clamp(command.durationMs / 1000f, 0f, 5f);
            HoldActionPose(duration);

            if (duration <= 0.001f)
            {
                bodyPoseTransitionActive = false;
                avatarRoot.localPosition = targetPosition;
                avatarRoot.localRotation = targetRotation;
                avatarRoot.localScale = targetScale;
                return;
            }

            bodyPoseStartPosition = avatarRoot.localPosition;
            bodyPoseStartRotation = avatarRoot.localRotation;
            bodyPoseStartScale = avatarRoot.localScale;
            bodyPoseTargetPosition = targetPosition;
            bodyPoseTargetRotation = targetRotation;
            bodyPoseTargetScale = targetScale;
            bodyPoseTransitionStartedAt = Time.realtimeSinceStartup;
            bodyPoseTransitionDurationSeconds = duration;
            bodyPoseTransitionActive = true;
        }

        private void UpdateBodyPoseTransition()
        {
            if (!bodyPoseTransitionActive || avatarRoot == null)
            {
                return;
            }

            float elapsed = Time.realtimeSinceStartup - bodyPoseTransitionStartedAt;
            float t = bodyPoseTransitionDurationSeconds <= 0f
                ? 1f
                : Mathf.Clamp01(elapsed / bodyPoseTransitionDurationSeconds);
            float eased = Mathf.SmoothStep(0f, 1f, t);
            avatarRoot.localPosition = Vector3.LerpUnclamped(
                bodyPoseStartPosition,
                bodyPoseTargetPosition,
                eased);
            avatarRoot.localRotation = Quaternion.SlerpUnclamped(
                bodyPoseStartRotation,
                bodyPoseTargetRotation,
                eased);
            avatarRoot.localScale = Vector3.LerpUnclamped(
                bodyPoseStartScale,
                bodyPoseTargetScale,
                eased);

            if (t < 1f)
            {
                return;
            }

            bodyPoseTransitionActive = false;
            avatarRoot.localPosition = bodyPoseTargetPosition;
            avatarRoot.localRotation = bodyPoseTargetRotation;
            avatarRoot.localScale = bodyPoseTargetScale;
        }

        private Vector3 BodyPosePosition(BodyPoseCommand command)
        {
            return baseRootPosition + new Vector3(
                Mathf.Clamp(command.x, -1f, 1f),
                Mathf.Clamp(command.y, -1f, 1f),
                Mathf.Clamp(command.z, -1.5f, 1.5f));
        }

        private Quaternion BodyPoseRotation(BodyPoseCommand command)
        {
            float yaw = Mathf.Clamp(command.yaw, -Mathf.PI, Mathf.PI) * Mathf.Rad2Deg;
            return baseRootRotation * Quaternion.Euler(0f, yaw, 0f);
        }

        private Vector3 BodyPoseScale(BodyPoseCommand command)
        {
            float scale = Mathf.Clamp(command.scale <= 0f ? 1f : command.scale, 0.55f, 1.35f);
            return baseRootScale * scale;
        }

        private void PlayMotion(MotionCommand command)
        {
            string type = Normalize(command.type);
            switch (type)
            {
                case "turn_left":
                    PlayTemporaryTurn(-0.45f, command);
                    break;
                case "turn_right":
                    PlayTemporaryTurn(0.45f, command);
                    break;
                case "turn_back":
                case "look_back":
                    PlayTemporaryTurn(Mathf.PI, command);
                    break;
                case "step_forward":
                    SetBodyPose(new BodyPoseCommand { z = -0.18f, scale = 1.03f });
                    break;
                case "step_back":
                    SetBodyPose(new BodyPoseCommand { z = 0.18f, scale = 0.98f });
                    break;
                case "reset":
                    SetBodyPose(new BodyPoseCommand { scale = 1f });
                    ClearGaze();
                    break;
                default:
                    ApplyPrimitive(type, command.Intensity);
                    if (command.options != null && command.options.durationMs > 0)
                    {
                        HoldActionPose(command.options.durationMs / 1000f);
                    }
                    break;
            }
        }

        private void PlayTemporaryTurn(float yaw, MotionCommand command)
        {
            if (avatarRoot == null || avatarLeasedToWorld) return;
            annieMotion.Stop();
            CancelTemporaryTurn();
            float holdSeconds = command.options != null && command.options.durationMs > 0
                ? command.options.durationMs / 1000f
                : idleActionHoldSeconds;
            holdSeconds = Mathf.Clamp(holdSeconds, 0.2f, 5f);
            temporaryTurnTransitionSeconds = Mathf.Min(0.35f, holdSeconds * 0.5f);
            temporaryTurnActive = true;
            temporaryTurnReturning = false;
            HoldActionPose(holdSeconds);
            StartRootRotationTransition(
                baseRootRotation * Quaternion.Euler(0f, yaw * Mathf.Rad2Deg, 0f),
                temporaryTurnTransitionSeconds);
        }

        private void StartRootRotationTransition(Quaternion target, float seconds)
        {
            bodyPoseStartPosition = avatarRoot.localPosition;
            bodyPoseTargetPosition = bodyPoseStartPosition;
            bodyPoseStartRotation = avatarRoot.localRotation;
            bodyPoseTargetRotation = target;
            bodyPoseStartScale = avatarRoot.localScale;
            bodyPoseTargetScale = bodyPoseStartScale;
            bodyPoseTransitionStartedAt = Time.realtimeSinceStartup;
            bodyPoseTransitionDurationSeconds = seconds;
            bodyPoseTransitionActive = true;
        }

        private void CancelTemporaryTurn()
        {
            if (!temporaryTurnActive) return;
            temporaryTurnActive = false;
            temporaryTurnReturning = false;
            bodyPoseTransitionActive = false;
        }

        private void PlayMotionSequence(MotionSequenceCommand command)
        {
            if (command.steps == null)
            {
                return;
            }

            for (int i = 0; i < command.steps.Length; i++)
            {
                MotionStepCommand step = command.steps[i];
                if (!string.IsNullOrWhiteSpace(step.clip))
                {
                    PlayAnimationClip(new AnimationClipCommand { id = step.clip, options = step.options });
                }
                else if (!string.IsNullOrWhiteSpace(step.motion))
                {
                    PlayMotion(new MotionCommand { type = step.motion, options = step.options });
                }
                else if (!string.IsNullOrWhiteSpace(step.primitive))
                {
                    PlayPrimitive(new PrimitiveCommand { type = step.primitive, options = step.options });
                }
                else if (step.bodyPose != null)
                {
                    SetBodyPose(step.bodyPose);
                }
            }
        }

        private void ApplyPrimitive(string type, float intensity)
        {
            ClearSpeechPerformanceCue();
            ReleaseAmbientBodyPerformance();
            upperBodyInertia.RequestTransition();
            float amp = Mathf.Clamp(intensity <= 0f ? 0.75f : intensity, 0.1f, 1.25f);
            HoldActionPose();
            if (TryPlayPrimitiveAnimation(type))
            {
                return;
            }

            switch (type)
            {
                case "wave":
                    RotateBone("upperarm_R", new Vector3(0f, 0f, -58f * amp));
                    RotateBone("lowerarm_R", new Vector3(0f, 0f, -38f * amp));
                    RotateBone("hand_R", new Vector3(0f, 0f, 24f * amp));
                    break;
                case "soft_wave":
                    RotateBone("upperarm_R", new Vector3(0f, 0f, -34f * amp));
                    RotateBone("lowerarm_R", new Vector3(0f, 0f, -24f * amp));
                    break;
                case "think":
                case "chest":
                case "hand_to_chest":
                    RotateBone("head", new Vector3(9f * amp, 0f, 0f));
                    RotateBone("upperarm_R", new Vector3(0f, 0f, -28f * amp));
                    RotateBone("lowerarm_R", new Vector3(0f, 0f, -48f * amp));
                    break;
                case "explain":
                case "palms_open":
                case "point_small":
                    RotateBone("upperarm_R", new Vector3(0f, 0f, -28f * amp));
                    RotateBone("lowerarm_R", new Vector3(0f, 0f, -22f * amp));
                    RotateBone("hand_R", new Vector3(0f, 18f * amp, 0f));
                    break;
                case "shy":
                case "shy_hands":
                case "look_away":
                    RotateBone("head", new Vector3(4f * amp, 22f * amp, 5f * amp));
                    RotateBone("upperarm_L", new Vector3(0f, 0f, -14f * amp));
                    RotateBone("upperarm_R", new Vector3(0f, 0f, 14f * amp));
                    break;
                case "nod":
                case "listen":
                    RotateBone("head", new Vector3(8f * amp, 0f, 0f));
                    break;
                case "shrug":
                    RotateBone("clavicle_L", new Vector3(0f, 0f, -12f * amp));
                    RotateBone("clavicle_R", new Vector3(0f, 0f, 12f * amp));
                    break;
                case "cheer":
                    RotateBone("upperarm_L", new Vector3(0f, 0f, 48f * amp));
                    RotateBone("upperarm_R", new Vector3(0f, 0f, -48f * amp));
                    break;
                case "jump":
                    if (avatarRoot != null)
                    {
                        avatarRoot.localPosition = baseRootPosition + Vector3.up * (0.08f * amp);
                    }
                    break;
                default:
                    RotateBone("head", new Vector3(3f * amp, 0f, 0f));
                    break;
            }
        }

        private bool TryPlayPrimitiveAnimation(string type)
        {
            string annieId = OpenAnnieMotionPlayback.SemanticClip(type);
            if (annieId != null && annieMotion.HasClip(annieId))
            {
                if (AnnieMotionBlocked()) return true;
                if (annieMotion.TryPlay(animator, annieId, Time.realtimeSinceStartup, false))
                {
                    HoldActionPose();
                    return true;
                }
            }
            if (TryPlayAnimatorState(type)) return true;
            // Reviewed on the default VRM: agree_234 is the short, arms-down
            // acknowledgement; agree is a larger open-hand explanation.
            string clipId = type switch
            {
                "think" => "thinking",
                "nod" => "agree_234",
                "cheer" => "excited",
                _ => null,
            };
            return clipId != null && TryPlayAnimatorState(clipId);
        }

        private bool TryPlayAnimatorState(string stateName)
        {
            if (stateName?.StartsWith(OpenAnnieMotionPlayback.Prefix, StringComparison.Ordinal) == true)
                return annieMotion.TryPlay(animator, stateName, Time.realtimeSinceStartup, AnnieMotionBlocked());
            if (animator == null || animator.runtimeAnimatorController == null || string.IsNullOrWhiteSpace(stateName))
            {
                return false;
            }

            if (!TryFindAnimatorState(stateName, out int layer, out int stateHash))
            {
                return false;
            }

            designedIdleActive = false;
            annieMotion.Stop();
            if (string.Equals(stateName, "standard_walk", StringComparison.OrdinalIgnoreCase))
                WorldLocomotionPresentation.ApplyDefaultWalkingAnimationSpeed(animator);
            animator.CrossFade(stateHash, 0.12f, layer);
            return true;
        }

        private bool TryFindAnimatorState(string stateName, out int layer, out int stateHash)
        {
            layer = -1;
            stateHash = 0;

            for (int layerIndex = 0; layerIndex < animator.layerCount; layerIndex++)
            {
                string layerName = animator.GetLayerName(layerIndex);
                string[] candidates =
                {
                    stateName,
                    $"{layerName}.{stateName}",
                };

                for (int i = 0; i < candidates.Length; i++)
                {
                    int candidateHash = Animator.StringToHash(candidates[i]);
                    if (!animator.HasState(layerIndex, candidateHash))
                    {
                        continue;
                    }

                    layer = layerIndex;
                    stateHash = candidateHash;
                    return true;
                }
            }

            return false;
        }

        private void RotateBone(string preferredName, Vector3 euler)
        {
            Transform bone = FindHumanoidPrimitiveBone(preferredName) ?? FindBone(preferredName);
            if (bone == null)
            {
                return;
            }

            bone.localRotation = BaseRotation(bone) * Quaternion.Euler(euler);
        }

        private Transform FindHumanoidPrimitiveBone(string preferredName)
        {
            if (animator == null || !animator.isHuman) return null;
            HumanBodyBones bone = Normalize(preferredName) switch
            {
                "head" => HumanBodyBones.Head,
                "neck" => HumanBodyBones.Neck,
                "clavicle_l" => HumanBodyBones.LeftShoulder,
                "clavicle_r" => HumanBodyBones.RightShoulder,
                "upperarm_l" => HumanBodyBones.LeftUpperArm,
                "upperarm_r" => HumanBodyBones.RightUpperArm,
                "lowerarm_l" => HumanBodyBones.LeftLowerArm,
                "lowerarm_r" => HumanBodyBones.RightLowerArm,
                "hand_l" => HumanBodyBones.LeftHand,
                "hand_r" => HumanBodyBones.RightHand,
                _ => HumanBodyBones.LastBone,
            };
            return bone == HumanBodyBones.LastBone ? null : animator.GetBoneTransform(bone);
        }

        private void HoldActionPose(float seconds = 0f)
        {
            designedIdleActive = false;
            activeDesignedIdleStateName = string.Empty;
            nextIdleStateAt = -1f;
            float holdSeconds = seconds > 0f ? seconds : idleActionHoldSeconds;
            holdSeconds = Mathf.Max(holdSeconds, annieMotion.Remaining(Time.realtimeSinceStartup));
            actionPoseHoldUntil = Time.realtimeSinceStartup + Mathf.Max(0.2f, holdSeconds);
        }

        private bool AnnieMotionBlocked() => hostBackgroundWorkPaused || !localVisibility.Visible || avatarRoot == null ||
            avatarLeasedToWorld || worldLocomotionActive || bodyPoseTransitionActive ||
            phoneInteraction?.OwnsHands == true || furniturePose.Active ||
            presenceTransition?.OwnsPresentation == true || doorwayTransition?.OwnsCamera == true ||
            agentSpace?.IsReturningHome == true;

        private bool SourceIdleBaselineAllowed() => !hostBackgroundWorkPaused && localVisibility.Visible && avatarRoot != null &&
            !avatarLeasedToWorld && !bodyPoseTransitionActive && !temporaryTurnActive &&
            phoneInteraction?.OwnsHands != true && !furniturePose.Active &&
            presenceTransition?.OwnsPresentation != true && doorwayTransition?.OwnsCamera != true &&
            agentSpace?.IsReturningHome != true;

        private static bool IsSpeechPerformanceGesture(string gesture) =>
            gesture is "speech" or "explain" or "palms_open" or "point_small" or "chest" or "listen";

        private static bool ValidPerformanceStyle(string energy, string emotion, float intensity) =>
            energy is "gentle" or "moderate" or "high" &&
            emotion is "neutral" or "calm" or "happy" or "excited" or "sad" or "comforting" or
                "curious" or "thinking" or "surprised" or "angry" &&
            !float.IsNaN(intensity) && !float.IsInfinity(intensity) && intensity >= 0f && intensity <= 1f;

        private bool QueueSpeechPerformanceCue(string gesture, string emotion, string energy,
            float intensity, long sequence, long deadline)
        {
            long nowMs = UtcEpochMilliseconds();
            if (avatarRoot == null || !IsSpeechPerformanceGesture(gesture) || !ValidPerformanceStyle(energy, emotion, intensity) ||
                sequence < 1 || deadline <= nowMs || !EnsureSpeechPerformance()) return false;
            // Replacing a live cue in the same audio episode updates the next
            // semantic gesture/style. Clearing it first would reset the
            // scheduler's raised-arm stroke and rest attack mid-sentence.
            // Expiry, listening, a new playback episode and explicit releases
            // retain their existing immediate retirement semantics.
            bool continuingSpeech = gesture != "listen" && performanceCueGesture != null &&
                performanceCueGesture != "listen" && nowMs <= performanceCueDeadlineMs &&
                speechPlaybackClock.Active && speechGestureEpoch == speechPlaybackClock.Epoch &&
                performanceCueTurnId == acceptedSpeechTurnId;
            if (!continuingSpeech) ClearSpeechPerformanceCue();
            performanceCueGesture = gesture;
            performanceCueEnergy = energy;
            performanceCueEmotion = emotion;
            performanceCueIntensity = intensity;
            performanceCueSequence = sequence;
            performanceCueDeadlineMs = Math.Min(deadline, nowMs + 5000);
            performanceCueTurnId = speechPlaybackClock.Active ? acceptedSpeechTurnId : null;
            performanceCueAppliedEpoch = -1;
            performanceCueSemanticConsumed = false;
            if (gesture == "listen")
            {
                float now = Time.realtimeSinceStartup;
                if (!conversationHintsEnabled) conversationMotion.Reset(now);
                conversationHintsEnabled = true;
                conversationMotion.SetPhase("listening", now);
                conversationalMicroMotion.SetPhase("listening", now);
                speechGestureAnimator.Release();
            }
            return avatarRoot != null;
        }

        private bool HasSpeechPerformanceCue()
        {
            if (performanceCueGesture == null) return false;
            if (UtcEpochMilliseconds() <= performanceCueDeadlineMs) return true;
            ClearSpeechPerformanceCue();
            return false;
        }

        private void ClearSpeechPerformanceCue()
        {
            if (performanceCueGesture == "listen")
            {
                conversationalMicroMotion.Reset();
                float now = Time.realtimeSinceStartup;
                // Retire the policy's own active-loop record as well as its
                // player. A rapid clear/requeue must not leave a ghost loop.
                conversationMotion.Advance(now, true, true);
                conversationMotion.SetPhase("stopped", now);
                if (conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip)
                {
                    annieMotion.Stop();
                    actionPoseHoldUntil = 0f;
                    upperBodyInertia.RequestTransitionAfterEvaluation();
                }
                conversationPolicyClip = null;
            }
            performanceCueGesture = performanceCueEnergy = performanceCueEmotion = performanceCueTurnId = null;
            performanceCueDeadlineMs = 0;
            performanceCueAppliedEpoch = -1;
            performanceCueSemanticConsumed = false;
            speechGestures.ClearPerformanceCue();
        }

        private void ApplyPendingSpeechPerformanceCue()
        {
            if (!HasSpeechPerformanceCue() || performanceCueAppliedEpoch == speechGestureEpoch ||
                performanceCueTurnId == null || performanceCueTurnId != acceptedSpeechTurnId) return;
            string gesture = performanceCueSemanticConsumed ? null : performanceCueGesture switch
            {
                "explain" => "annie_g_offer_r",
                "palms_open" => "annie_g_open_both",
                "point_small" => "annie_g_point_r",
                "chest" => "annie_g_chest_r",
                _ => null,
            };
            if (speechGestures.QueuePerformanceCue(speechGestureEpoch, performanceCueSequence,
                gesture, performanceCueEmotion, performanceCueEnergy == "gentle" ? "calm" : performanceCueEnergy,
                performanceCueIntensity))
            {
                performanceCueAppliedEpoch = speechGestureEpoch;
                performanceCueSemanticConsumed = true;
            }
        }

        private bool FreeConversationMotionAllowed(float now)
        {
            bool ownPolicy = conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip;
            // Chest/hand contacts are deliberately authored into a complete
            // pose. A generic clearance capsule must not push that touch away.
            bool authoredContact = performanceLibrary != null && speechGestureAnimator.ActiveId != null &&
                performanceLibrary.TryGet(speechGestureAnimator.ActiveId, out var entry) && entry.Contact;
            return !authoredContact && !AnnieMotionBlocked() && !temporaryTurnActive &&
                (!annieMotion.Active || ownPolicy) && (now >= actionPoseHoldUntil || ownPolicy) &&
                (HostBackgroundWorkAuthorityReleased() || HasSpeechPerformanceCue());
        }

        private bool EnsureSpeechPerformance()
        {
            if (performanceInitialized) return performanceLibrary != null;
            performanceLibrary = Resources.Load<OpenAnnieMotionLibrary>(OpenAnnieMotionLibrary.ResourceName);
            if (performanceLibrary == null) return false;
            speechGestures.Initialize(performanceLibrary, 1729);
            performanceInitialized = true;
            return true;
        }

        private bool SyncSpeechPlaybackClock(AvatarSpeechPlaybackClockPacket packet)
        {
            float now = Time.realtimeSinceStartup;
            if (!speechPlaybackClock.Apply(packet, now)) return false;
            if (packet.state == "start")
            {
                acceptedSpeechTurnId = packet.turnId;
                if (performanceCueGesture == "listen") ClearSpeechPerformanceCue();
                if (HasSpeechPerformanceCue())
                {
                    if (performanceCueTurnId == null) performanceCueTurnId = packet.turnId;
                    else if (performanceCueTurnId != packet.turnId) ClearSpeechPerformanceCue();
                }
                performanceCueAppliedEpoch = -1;
            }
            if (packet.state == "start")
            {
                speechGestureAnimator.Release();
                speechGestures.Stop();
                speechMouthBound = speechPlaybackClock.MatchesEnvelope(lipSyncEnvelope, lipSyncFrameRate);
                speechGestureEpoch = -1;
            }
            if (packet.state != "stop" &&
                speechPlaybackClock.MatchesEnvelope(lipSyncEnvelope, lipSyncFrameRate)) speechMouthBound = true;
            if (packet.state is "start" or "resume")
            {
                if (HostBackgroundWorkAuthorityReleased() && EnsureSpeechPerformance())
                {
                    if (!conversationHintsEnabled) conversationMotion.Reset(now);
                    conversationHintsEnabled = true;
                    conversationMotion.SetPhase("speaking", now);
                    conversationalMicroMotion.SetPhase("speaking", now);
                    // Stop an idle fidget before the acoustic layer takes the
                    // hands. Ordinary idle remains available as the base pose.
                    if (conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip &&
                        AvatarConversationMotionPolicy.IsInterlude(conversationPolicyClip))
                    {
                        ReleaseAmbientBodyPerformance();
                        TryStartDesignedIdle(designedIdleStateName);
                        upperBodyInertia.RequestTransitionAfterEvaluation();
                    }
                }
            }
            if (packet.state == "stop")
            {
                if (speechGestureAnimator.ActiveId != null) upperBodyInertia.RequestTransitionAfterEvaluation();
                speechGestureAnimator.Release();
                speechGestures.Stop();
                if (speechMouthBound) StopLipSync();
                speechMouthBound = false;
                conversationMotion.SetPhase("stopped", now);
            }
            else if (packet.state == "pause")
            {
                ClearSpeechPerformanceCue();
                conversationalMicroMotion.Reset();
                if (speechGestureAnimator.ActiveId != null) upperBodyInertia.RequestTransitionAfterEvaluation();
                speechGestureAnimator.Release();
                if (speechMouthBound) StopLipSync();
            }
            else if (packet.state == "resume" && speechMouthBound && lipSyncEnvelope != null)
            {
                lipSyncStartedAt = now - packet.positionMs / 1000f;
                lipSyncActive = true;
            }
            return true;
        }

        private void SetConversationPhase(string json)
        {
            if (!HasExactJsonObjectFields(json, new HashSet<string> { "phase", "sequence" }, out var fields) ||
                !IsJsonStringToken(fields["phase"]) || !IsJsonIntegerToken(fields["sequence"])) return;
            var phase = FromJson<ConversationPhaseCommand>(json);
            if (phase.sequence <= conversationPhaseSequence || phase.sequence > MaximumExactJsonInteger ||
                phase.phase is not "listening" and not "thinking" and not "speaking" and not "stopped") return;
            if (!EnsureSpeechPerformance()) return;
            if (!conversationHintsEnabled) conversationMotion.Reset(Time.realtimeSinceStartup);
            conversationHintsEnabled = true;
            conversationPhaseSequence = phase.sequence;
            conversationMotion.SetPhase(phase.phase, Time.realtimeSinceStartup);
            conversationalMicroMotion.SetPhase(phase.phase, Time.realtimeSinceStartup);
            if (phase.phase is "listening" or "stopped") ClearSpeechPerformanceCue();
        }

        private void AdvanceSpeechPerformance(float now)
        {
            if ((!conversationHintsEnabled && !speechPlaybackClock.Active) || !EnsureSpeechPerformance()) return;
            bool ownPolicy = conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip;
            bool blocked = AnnieMotionBlocked() ||
                (!HostBackgroundWorkAuthorityReleased() && !HasSpeechPerformanceCue());
            if (AnnieMotionBlocked()) ClearSpeechPerformanceCue();
            bool explicitBody = (annieMotion.Active && !ownPolicy) || temporaryTurnActive ||
                (now < actionPoseHoldUntil && !ownPolicy);
            if (explicitBody) ClearSpeechPerformanceCue();
            if (performanceCueGesture != "listen" && speechPlaybackClock.Active &&
                speechPlaybackClock.Envelope != null && speechPlaybackClock.Authoritative)
            {
                if (speechGestureEpoch != speechPlaybackClock.Epoch)
                {
                    speechGestures.Start(speechPlaybackClock.Epoch, speechPlaybackClock.Envelope, speechPlaybackClock.FrameRate);
                    speechGestureEpoch = speechPlaybackClock.Epoch;
                }
                ApplyPendingSpeechPerformanceCue();
                var sample = speechGestures.Tick(speechGestureEpoch, speechPlaybackClock.Position(now),
                    speechPlaybackClock.IsPlaying(now), blocked || explicitBody);
                string oldState = speechGestureAnimator.ActiveId;
                string nextState = sample.Active ? sample.Entry.Id : null;
                bool direct = CanUseNormalizedPose(sample.Entry);
                // A direct source is sampled later in THIS presentation frame.
                // Native Animator selection instead takes effect at its next
                // evaluation, so only that path uses deferred transition setup.
                if (!direct && !speechGestureAnimator.UsesDirectSource && oldState != nextState)
                    upperBodyInertia.RequestSourceTransitionAfterEvaluation();
                if (direct) speechGestureAnimator.ApplyDirectSource(animator, sample, blocked || explicitBody);
                else speechGestureAnimator.Apply(animator, sample, blocked || explicitBody);
            }
            else speechGestureAnimator.Release();
            var decision = conversationMotion.Advance(now, blocked, explicitBody);
            if (decision == null) return;
            if (decision.ClipId == AvatarConversationMotionPolicy.BaseIdleState)
            {
                upperBodyInertia.RequestTransitionAfterEvaluation();
                if (!annieMotion.TryPlayBaseIdle(animator, decision.ClipId, now, blocked, decision.HoldSeconds))
                { conversationMotion.Reject(decision.ClipId, now); return; }
                conversationPolicyClip = decision.ClipId;
                // Animator retains the native clip's own clock. The policy
                // tracks its renewable lease only, not an invented source FK.
                conversationMotion.NotifyPlayed(decision.ClipId, now, decision.HoldSeconds, true);
                return;
            }
            if (!performanceLibrary.TryGet(decision.ClipId, out var entry))
            { conversationMotion.Reject(decision.ClipId, now); return; }
            upperBodyInertia.RequestTransitionAfterEvaluation();
            if (!annieMotion.TryPlayAtPhase(animator, decision.ClipId, now, blocked,
                decision.IsFidget ? 0f : decision.HoldSeconds, decision.NormalizedTime))
            { conversationMotion.Reject(decision.ClipId, now); return; }
            conversationPolicyClip = decision.ClipId;
            conversationMotion.NotifyPlayed(entry.Id, now, entry.Duration, entry.Loop);
            HoldActionPose();
        }

        private bool CanUseNormalizedPose(OpenAnnieMotionLibrary.Entry entry) =>
            normalizedArmPose.Bound && entry?.NormalizedPose != null &&
            entry.NormalizedPose.SourceSha256 == entry.SourceSha256 &&
            entry.NormalizedPose.SourceCommit == OpenAnnieMotionLibrary.UpstreamCommit &&
            entry.NormalizedPose.Frames >= 2 && entry.NormalizedPose.FramesPerSecond > 0f;

        // Exactly one source owns arms/fingers after Animator and before
        // source-switch inertia. Phone, furniture, entrance, locomotion and
        // visibility owners keep their immediate takeover path.
        private bool AdvanceNormalizedArmPose()
        {
            if (AnnieMotionBlocked() || !normalizedArmPose.Bound || animator == null)
            {
                normalizedArmPose.Release();
                normalizedPoseEntry = null;
                return false;
            }
            OpenAnnieMotionLibrary.Entry selected = null;
            float seconds = 0f;
            bool torso = false;
            bool speech = false;
            long episode = 0;
            var sample = speechGestureAnimator.CurrentSample;
            if (speechGestureAnimator.UsesDirectSource && sample.Active && CanUseNormalizedPose(sample.Entry))
            {
                selected = sample.Entry;
                seconds = sample.ClipSeconds;
                torso = !gazeActive;
                speech = true;
                episode = speechPlaybackClock.Epoch;
            }
            else if (annieMotion.Active && EnsureSpeechPerformance() &&
                performanceLibrary.TryGet(annieMotion.ActiveId, out var body) && CanUseNormalizedPose(body))
            {
                int layer = body.UpperBody ? animator.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName) : 0;
                if (layer >= 0 && layer < animator.layerCount)
                {
                    int expected = Animator.StringToHash(body.Id);
                    var state = animator.GetCurrentAnimatorStateInfo(layer);
                    if (animator.IsInTransition(layer))
                    {
                        var next = animator.GetNextAnimatorStateInfo(layer);
                        if (next.shortNameHash == expected) state = next;
                    }
                    if (state.shortNameHash == expected && !float.IsNaN(state.normalizedTime) &&
                        !float.IsInfinity(state.normalizedTime))
                    {
                        selected = body;
                        episode = annieMotion.EpisodeId;
                        seconds = (body.Loop ? Mathf.Repeat(state.normalizedTime, 1f) :
                            Mathf.Clamp01(state.normalizedTime)) * body.Duration;
                    }
                }
            }
            bool applied = selected != null && normalizedArmPose.Apply(selected, seconds, 1f, torso);
            if (!applied) { normalizedArmPose.Release(); selected = null; torso = false; }
            // CrossFade selected in LateUpdate may expose the old same-name
            // state until the next Animator evaluation. Also recognize its
            // actual non-loop cursor reset, not only its admission episode.
            bool restartedCursor = selected != null && selected == normalizedPoseEntry &&
                !selected.Loop && seconds + .0001f < normalizedPoseSeconds;
            if (selected != normalizedPoseEntry || restartedCursor || (selected != null &&
                (speech != normalizedPoseSpeech || episode != normalizedPoseEpisode)))
                upperBodyInertia.RequestSourceTransition();
            else if (torso != normalizedPoseTorso)
                upperBodyInertia.RequestTransition();
            normalizedPoseEntry = selected;
            normalizedPoseTorso = torso;
            normalizedPoseSpeech = speech;
            normalizedPoseEpisode = episode;
            normalizedPoseSeconds = seconds;
            return applied;
        }

        private void ReleaseAmbientBodyPerformance()
        {
            speechGestureAnimator.Release();
            conversationMotion.Advance(Time.realtimeSinceStartup, true, true);
            if (conversationPolicyClip != null && annieMotion.ActiveId == conversationPolicyClip)
            {
                annieMotion.Stop();
                actionPoseHoldUntil = 0f;
            }
            conversationPolicyClip = null;
        }

        private void ResetSpeechPerformance()
        {
            speechPlaybackClock.Reset();
            speechMouthBound = false;
            speechGestureEpoch = -1;
            speechGestures.Stop();
            ReleaseAmbientBodyPerformance();
            ClearSpeechPerformanceCue();
            performanceBodyChannel = false;
            acceptedSpeechTurnId = null;
            activeArmDeformation?.RestoreBeforeAnimation();
            freeGestureCollision.Reset();
            guardWasAppliedLastFrame = false;
            // A speech/authority reset does not replace the current model.
            // Preserve its cached binding so the next listening episode works.
            conversationalMicroMotion.Reset();
            upperBodyInertia.Bind(null);
            normalizedArmPose.Release();
            normalizedPoseEntry = null;
            normalizedPoseTorso = false;
            normalizedPoseSpeech = false;
            normalizedPoseEpisode = 0;
            normalizedPoseSeconds = 0f;
            conversationMotion.Reset(Time.realtimeSinceStartup);
            conversationPhaseSequence = 0;
            conversationHintsEnabled = false;
        }

        private Transform FindBone(params string[] preferredNames)
        {
            EnsureAvatarRootOnly();
            for (int i = 0; i < preferredNames.Length; i++)
            {
                string preferred = Normalize(preferredNames[i]);
                if (bones.TryGetValue(preferred, out Transform exact))
                {
                    return exact;
                }

                foreach (KeyValuePair<string, Transform> pair in bones)
                {
                    if (pair.Key.Contains(preferred))
                    {
                        return pair.Value;
                    }
                }
            }

            return null;
        }

        private Transform FindEyeBone(bool left)
        {
            EnsureAvatarRootOnly();
            if (animator != null && animator.isHuman)
            {
                Transform humanoidEye = animator.GetBoneTransform(
                    left ? HumanBodyBones.LeftEye : HumanBodyBones.RightEye);
                if (humanoidEye != null)
                {
                    return humanoidEye;
                }
            }

            string[] exactNames = left
                ? new[] { "eye_l", "left_eye", "lefteye" }
                : new[] { "eye_r", "right_eye", "righteye" };

            for (int i = 0; i < exactNames.Length; i++)
            {
                if (bones.TryGetValue(exactNames[i], out Transform exact))
                {
                    return exact;
                }
            }

            for (int i = 0; i < exactNames.Length; i++)
            {
                string exactName = exactNames[i];
                foreach (KeyValuePair<string, Transform> pair in bones)
                {
                    if (pair.Key.Contains("eye") && pair.Key.Contains(left ? "l" : "r") && pair.Key.Contains(exactName.Replace("_", string.Empty)))
                    {
                        return pair.Value;
                    }
                }
            }

            foreach (KeyValuePair<string, Transform> pair in bones)
            {
                if (!pair.Key.Contains("eye"))
                {
                    continue;
                }

                if (left && (pair.Key.Contains("_l") || pair.Key.StartsWith("l", StringComparison.Ordinal) || pair.Key.Contains("left")))
                {
                    return pair.Value;
                }

                if (!left && (pair.Key.Contains("_r") || pair.Key.StartsWith("r", StringComparison.Ordinal) || pair.Key.Contains("right")))
                {
                    return pair.Value;
                }
            }

            return null;
        }

        private Transform FindUpperBodyBone()
        {
            EnsureAvatarRootOnly();
            if (animator != null && animator.isHuman)
            {
                Transform humanoidBone =
                    animator.GetBoneTransform(HumanBodyBones.UpperChest) ??
                    animator.GetBoneTransform(HumanBodyBones.Chest) ??
                    animator.GetBoneTransform(HumanBodyBones.Spine);
                if (humanoidBone != null)
                {
                    return humanoidBone;
                }
            }

            return FindBone(
                "upper_chest",
                "upperchest",
                "chest",
                "spine_03",
                "spine_02",
                "spine");
        }

        private void EnsureAvatarRootOnly()
        {
            if (avatarRoot == null)
            {
                avatarRoot = FindDefaultTarget() ?? transform;
                CacheBones();
            }
        }

        private Quaternion BaseRotation(Transform bone)
        {
            if (bone != null && baseRotations.TryGetValue(bone, out Quaternion rotation))
            {
                return rotation;
            }

            return Quaternion.identity;
        }

        private void SetBlendShapeAliasGroups(float value, string[][] groups)
        {
            float weight = Clamp01(value) * 100f;
            bool selected = false;
            for (int i = 0; i < groups.Length; i++)
            {
                string[] group = groups[i];
                bool groupExists = HasAnyBlendShape(group);
                if (!selected && groupExists)
                {
                    SetBlendShapeGroup(group, weight);
                    selected = true;
                }
                else
                {
                    SetBlendShapeGroup(group, 0f);
                }
            }
        }

        private void SetNonVrmMouthVisemes(
            float aa,
            float ih,
            float ou,
            float ee,
            float oh)
        {
            float closure = 1f - Mathf.Clamp01(mouthVisemePp * 2f);
            if (!facialCalibration.IsCalibrated && !lipSyncActive && mouthOpen <= 0)
                oh = Mathf.Max(oh, currentExpression.surprised * .5f);
            aa *= closure; ih *= closure; ou *= closure; ee *= closure; oh *= closure;
            if (HasNativeMattMouthShapes())
            {
                // The Character Creator source uses these six native morphs.
                // Ih/Ee share V_Wide and Aa/Ee share V_Open, so aggregate each
                // source channel once instead of letting alias groups erase it.
                SetBlendShape("V_Explosive", mouthVisemePp * 100f);
                SetBlendShape("V_Dental_Lip", mouthVisemeFf * closure * 100f);
                SetBlendShape("V_Open", Mathf.Clamp01(aa + ih * .12f + ee * .3f) * 100f);
                SetBlendShape("V_Wide", Mathf.Clamp01(ih * .75f + ee * .65f) * 100f);
                SetBlendShape("V_Tight", ou * .85f * 100f);
                SetBlendShape("V_Tight_O", oh * 100f);
                return;
            }
            bool hasFf = HasAnyBlendShapeGroup(MouthFfBlendShapeGroups);
            SetBlendShapeAliasGroups(mouthVisemePp, MouthPpBlendShapeGroups);
            SetBlendShapeAliasGroups(mouthVisemeFf * closure, MouthFfBlendShapeGroups);
            if (!hasFf) ee = Mathf.Max(ee, mouthVisemeFf * .25f * closure);
            bool hasIh = HasAnyBlendShapeGroup(MouthIhBlendShapeGroups);
            bool hasOu = HasAnyBlendShapeGroup(MouthOuBlendShapeGroups);
            bool hasEe = HasAnyBlendShapeGroup(MouthEeBlendShapeGroups);
            bool hasOh = HasAnyBlendShapeGroup(MouthOhBlendShapeGroups);
            SetBlendShapeAliasGroups(ih, MouthIhBlendShapeGroups);
            SetBlendShapeAliasGroups(ou, MouthOuBlendShapeGroups);
            SetBlendShapeAliasGroups(ee, MouthEeBlendShapeGroups);
            SetBlendShapeAliasGroups(oh, MouthOhBlendShapeGroups);
            float fallbackAa = Mathf.Max(
                aa,
                hasIh ? 0f : ih,
                hasOu ? 0f : ou,
                hasEe ? 0f : ee,
                hasOh ? 0f : oh);
            SetBlendShapeAliasGroups(fallbackAa, MouthBlendShapeGroups);
        }

        private bool HasNativeMattMouthShapes()
        {
            Mesh mesh = faceRenderer?.sharedMesh;
            if (mesh == null) return false;
            foreach (string name in NativeMattMouthShapes)
                if (mesh.GetBlendShapeIndex(name) < 0) return false;
            return true;
        }

        private bool HasAnyBlendShapeGroup(string[][] groups)
        {
            for (int index = 0; index < groups.Length; index++)
            {
                if (HasAnyBlendShape(groups[index])) return true;
            }
            return false;
        }

        private bool HasAnyBlendShape(string[] names)
        {
            Mesh mesh = faceRenderer.sharedMesh;
            for (int i = 0; i < names.Length; i++)
            {
                if (mesh.GetBlendShapeIndex(names[i]) >= 0)
                {
                    return true;
                }
            }

            return false;
        }

        private void SetBlendShapeGroup(string[] names, float weight)
        {
            for (int i = 0; i < names.Length; i++)
            {
                SetBlendShape(names[i], weight);
            }
        }

        private void SetBlendShape(string name, float weight)
        {
            Mesh mesh = faceRenderer.sharedMesh;
            int index = mesh.GetBlendShapeIndex(name);
            if (index < 0)
            {
                return;
            }

            faceRenderer.SetBlendShapeWeight(index, weight);
        }

        private static SkinnedMeshRenderer FindFaceRenderer(Transform root)
        {
            if (root == null)
            {
                return null;
            }

            SkinnedMeshRenderer[] renderers = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            SkinnedMeshRenderer fallback = null;
            SkinnedMeshRenderer best = null;
            int bestScore = 0;
            for (int i = 0; i < renderers.Length; i++)
            {
                SkinnedMeshRenderer renderer = renderers[i];
                if (renderer == null || renderer.sharedMesh == null)
                {
                    continue;
                }

                if (fallback == null)
                {
                    fallback = renderer;
                }

                int score = FaceBlendShapeScore(renderer);
                if (score > bestScore)
                {
                    best = renderer;
                    bestScore = score;
                }
            }

            return best != null ? best : fallback;
        }

        private static int FaceBlendShapeScore(SkinnedMeshRenderer renderer)
        {
            if (renderer == null || renderer.sharedMesh == null)
            {
                return 0;
            }

            Mesh mesh = renderer.sharedMesh;
            int score = 0;
            for (int i = 0; i < FaceBlendShapeProbeNames.Length; i++)
            {
                if (mesh.GetBlendShapeIndex(FaceBlendShapeProbeNames[i]) >= 0)
                {
                    score++;
                }
            }

            return score;
        }

        private static Transform FindDefaultTarget()
        {
            SkinnedMeshRenderer[] renderers = FindObjectsByType<SkinnedMeshRenderer>(FindObjectsInactive.Exclude);
            return renderers.Length == 0 ? null : renderers[0].transform.root;
        }

        private static T FromJson<T>(string json) where T : new()
        {
            if (string.IsNullOrWhiteSpace(json))
            {
                return new T();
            }

            try
            {
                return JsonUtility.FromJson<T>(json) ?? new T();
            }
            catch (Exception)
            {
                return new T();
            }
        }

        private static float Clamp01(float value) => Mathf.Clamp01(float.IsNaN(value) ? 0f : value);

        private static float ClampUnit(float value) => Mathf.Clamp(float.IsNaN(value) ? 0f : value, -1f, 1f);

        private static string Normalize(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            return value.Trim().ToLowerInvariant().Replace("-", "_").Replace(" ", "_");
        }

        [Serializable]
        private sealed class AvatarArbiterCommand
        {
            public int protocolVersion;
            public string requestId;
            public long ticket;
            public string rendererId;
            public string ownerToken;
            public string commitToken;
            public long accountGeneration;
            public long rendererGeneration;
            public string channel;
            public string fingerprint;
            public string payloadJson;
            public string payloadSha256;
            public long deadlineEpochMs;
            public bool clearsChannel;
        }

        [Serializable]
        private sealed class AvatarArbiterRendererPayload
        {
            public string channel;
            public bool clear;
            public float value;
            public string format;
            public float[] envelope;
            public LipSyncVisemeCue[] cues;
            public int frameRate;
            public AvatarExpressionCommand @params;
            public GazeCommand gaze;
            public string gesture;
            public string workSessionId, workPhase;
            public string energy, emotion;
            public float intensity;
            public long leaseExpiresAtEpochMs;
            public string mode;
            public AvatarSpeechPlaybackClockPacket playbackClock;
        }

        [Serializable]
        private sealed class AvatarArbiterReset
        {
            public int protocolVersion;
            public string requestId;
            public long requirementId;
            public string rendererId;
            public string targetOwnerToken;
            public string commitToken;
            public long retiredAccountGeneration;
            public long retiredRendererGeneration;
            public long targetAccountGeneration;
            public long targetRendererGeneration;
            public string payloadJson;
            public string payloadSha256;
            public long deadlineEpochMs;
        }

        [Serializable]
        private sealed class AvatarArbiterCommandResult
        {
            public int protocolVersion;
            public string requestId;
            public string method;
            public bool ok;
            public string code;
            public long ticket;
            public string rendererId;
            public string ownerToken;
            public string commitToken;
            public long accountGeneration;
            public long rendererGeneration;
            public string channel;
            public string fingerprint;
            public string payloadSha256;
            public long deadlineEpochMs;
            public bool clearsChannel;
        }

        [Serializable]
        private sealed class AvatarArbiterResetResult
        {
            public int protocolVersion;
            public string requestId;
            public string method;
            public bool ok;
            public string code;
            public long requirementId;
            public string rendererId;
            public string targetOwnerToken;
            public string commitToken;
            public long retiredAccountGeneration;
            public long retiredRendererGeneration;
            public long targetAccountGeneration;
            public long targetRendererGeneration;
            public string payloadSha256;
            public long deadlineEpochMs;
        }

        [Serializable]
        private sealed class CommandEnvelope
        {
            public string method;
            public string json;
        }

        [Serializable]
        private sealed class AvatarLoadCommand
        {
            public string requestId;
            public string modelUrl;
            public AvatarLoadRuntimeConfig config;
        }

        [Serializable]
        private sealed class AvatarLoadRuntimeConfig
        {
            public string modelKey;
            public int assetVersion;
            public string assetName;
            public string assetFormat;
            public string approvedAssetSha256;
            public long approvedAssetBytes;
        }

        [Serializable]
        private sealed class AvatarLoadResult
        {
            public int backgroundTaskWorkVersion = 2;
            public string requestId;
            public string method;
            public bool ok;
            public string code;
            public string message;
            public bool cacheHit;
            public string assetSha256;
            public AvatarCapabilityProfile capabilityProfile;
        }

        [Serializable]
        private sealed class AvatarLoadResultWithoutCapabilityProfile
        {
            public int backgroundTaskWorkVersion = 2;
            public string requestId;
            public string method;
            public bool ok;
            public string code;
            public string message;
            public bool cacheHit;
            public string assetSha256;
        }

        [Serializable]
        private sealed class AvatarExpressionCommand
        {
            public float happy;
            public float sad;
            public float angry;
            public float surprised;
            public float love;
            public float relaxed;
            public float thinking;
            public float tired;
            public float mouthSmile;
            public float mouthOpen;
            public float eyeOpen = 1f;
            public float browConcern;

            public static AvatarExpressionCommand Default => new() { eyeOpen = 1f };

            public AvatarExpressionCommand WithDefaults()
            {
                if (eyeOpen <= 0f &&
                    happy == 0f &&
                    sad == 0f &&
                    angry == 0f &&
                    surprised == 0f &&
                    love == 0f &&
                    relaxed == 0f &&
                    thinking == 0f &&
                    tired == 0f &&
                    mouthSmile == 0f &&
                    mouthOpen == 0f &&
                    browConcern == 0f)
                {
                    eyeOpen = 1f;
                }

                eyeOpen = Mathf.Clamp01(eyeOpen);
                return this;
            }
        }

        [Serializable]
        private sealed class MouthOpenCommand
        {
            public float value;
        }

        [Serializable]
        private sealed class WorldTimeOfDayCommand
        {
            public string timeOfDay;
        }

        [Serializable]
        private sealed class ConversationPhaseCommand
        {
            public string phase;
            public long sequence;
        }

        [Serializable]
        private sealed class LipSyncCommand
        {
            public string format;
            public float[] envelope;
            public LipSyncVisemeCue[] cues;
            public int frameRate;
        }

        [Serializable]
        private sealed class LipSyncVisemeCue
        {
            public int frame;
            public string viseme;
        }

        private struct VrmVisemeWeights
        {
            public float aa;
            public float ih;
            public float ou;
            public float ee;
            public float oh;
        }

        [Serializable]
        private sealed class GazeCommand
        {
            public float eyeX;
            public float eyeY;
            public float headX;
            public float headY;
            public float headRoll;
            public float upperBodyX;

            public static GazeCommand Center => new();

            public GazeCommand Clamped() => new()
            {
                eyeX = ClampUnit(eyeX),
                eyeY = ClampUnit(eyeY),
                headX = ClampUnit(headX),
                headY = ClampUnit(headY),
                headRoll = ClampUnit(headRoll),
                upperBodyX = ClampUnit(upperBodyX),
            };
        }

        private struct AppliedGazeBoneState
        {
            public Quaternion lastDelta;
            public Quaternion lastResult;
        }

        [Serializable]
        private sealed class PrimitiveOptions
        {
            public float intensity = 0.75f;
            public float amplitude;
            public string energy, emotion;
            public int durationMs;

            public static PrimitiveOptions Default => new();

            public float Intensity => amplitude > 0f ? amplitude : intensity;
        }

        [Serializable]
        private sealed class PrimitiveCommand
        {
            public string type;
            public PrimitiveOptions options;
        }

        [Serializable]
        private sealed class AnimationClipCommand
        {
            public string id;
            public PrimitiveOptions options;

            public float Intensity => options?.Intensity ?? 0.75f;

            public float HoldSeconds => options != null && options.durationMs > 0
                ? options.durationMs / 1000f
                : 0f;
        }

        [Serializable]
        private sealed class ScreenTapCommand
        {
            public float x = 0.5f;
            public float y = 0.5f;
            public float normalizedX = -1f;
            public float normalizedY = -1f;
            public int durationMs = 1600;

            public float X => normalizedX >= 0f ? normalizedX : x;

            public float Y => normalizedY >= 0f ? normalizedY : y;

            public float HoldSeconds => durationMs > 0 ? durationMs / 1000f : 1.6f;
        }

        [Serializable]
        private sealed class HandTargetCommand
        {
            public string target;
            public PrimitiveOptions options;

            public float Intensity => options?.Intensity ?? 0.75f;
        }

        [Serializable]
        private sealed class BodyPoseCommand
        {
            public float yaw;
            public float x;
            public float y;
            public float z;
            public float scale = 1f;
            public int durationMs;
        }

        [Serializable]
        private sealed class MotionCommand
        {
            public string type;
            public PrimitiveOptions options;

            public float Intensity => options?.Intensity ?? 0.75f;
        }

        [Serializable]
        private sealed class MotionStepCommand
        {
            public string clip;
            public string motion;
            public string primitive;
            public PrimitiveOptions options;
            public BodyPoseCommand bodyPose;
        }

        [Serializable]
        private sealed class MotionSequenceCommand
        {
            public MotionStepCommand[] steps;
        }

        [Serializable]
        private sealed class FramingCommand
        {
            public string mode;
        }

        [Serializable]
        private sealed class ViewportSafeAreaCommand
        {
            public float topSafeViewport;
            public float bottomSafeViewport;
            public float top;
            public float bottom;

            public float Top => topSafeViewport != 0f ? topSafeViewport : top;

            public float Bottom => bottomSafeViewport != 0f ? bottomSafeViewport : bottom;
        }
    }
}
