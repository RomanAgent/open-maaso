using System.Collections.Generic;
using Maaso.Avatar;
using UnityEngine;

namespace Maaso.World
{
    [DisallowMultipleComponent]
    public sealed class PersistentWorldMapController : MonoBehaviour
    {
        public const float GroundY = 0f;
        public const float PersonalSpaceRoomSize = 8f;
        public const float PersonalSpaceClearRadius = 1.55f;
        private const float PersonalSpaceSpawnRadius = 1.2f;
        public const string ResourceName = "PersonalSpaceMap";
        public const string PersonalSpaceResourceName = "PersonalSpaceModel";
        public const string PersonalSpaceMaterialResourceName =
            "PersonalSpaceWhiteModel";

        private const int HomeAlignmentMinimumSamples = 6;
        private const int HomeAlignmentRequiredStableSamples = 3;
        private const int HomeAlignmentMaximumSamples = 30;
        private const float HomeAlignmentPositionEpsilon = 0.002f;

        [SerializeField] private Transform homeAgentAnchor;
        [SerializeField] private Transform homeCameraReference;
        [SerializeField] private Transform worldPlayCenter;
        [SerializeField] private Transform[] worldSpawnAnchors = System.Array.Empty<Transform>();
        [SerializeField] private Transform persistentEnvironmentRoot;
        [SerializeField] private Transform worldDecorationRoot;
        [SerializeField] private Collider groundCollider;

        private static PersistentWorldMapController current;
        private Collider fallbackGroundCollider;
        private bool worldActive;
        private UnityAvatarCommandReceiver avatarReceiver;
        private Transform alignedHomeAvatar;
        private Transform registeredPersistentEnvironment;
        private Transform settlingHomeAvatar;
        private Vector3 lastHomeAlignmentPosition;
        private int homeAlignmentSampleCount;
        private int homeAlignmentStableSampleCount;
        private bool hasLastHomeAlignmentPosition;

        public Transform HomeAgentAnchor => homeAgentAnchor;
        public Transform HomeCameraReference => homeCameraReference;
        public Transform WorldPlayCenter => worldPlayCenter;
        public IReadOnlyList<Transform> WorldSpawnAnchors => worldSpawnAnchors;
        public Transform PersistentEnvironmentRoot => persistentEnvironmentRoot;
        public Transform WorldDecorationRoot => worldDecorationRoot;
        public Collider GroundCollider => groundCollider ?? fallbackGroundCollider;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            if (Application.isPlaying)
            {
                InitializeDefaultMap();
            }
        }

        private static PersistentWorldMapController InitializeDefaultMap() =>
            EnsureRuntimeMap();

        private void Awake()
        {
            fallbackGroundCollider ??= groundCollider;
            if (current == null)
            {
                current = this;
            }
            if (Application.isPlaying)
            {
                DontDestroyOnLoad(gameObject);
            }
        }

        private void OnDestroy()
        {
            if (current == this)
            {
                current = null;
            }
        }

        private void LateUpdate()
        {
            if (!Application.isPlaying || worldActive)
            {
                return;
            }

            TryAlignActiveHomeAvatar();
        }

        private bool TryAlignActiveHomeAvatar()
        {
            if (avatarReceiver == null)
            {
                avatarReceiver = FindAnyObjectByType<UnityAvatarCommandReceiver>(
                    FindObjectsInactive.Include);
            }
            Transform activeAvatar = avatarReceiver?.ActiveAvatarRoot;
            if (activeAvatar == null)
            {
                ResetHomeAlignmentTracking();
                return false;
            }
            if (activeAvatar == alignedHomeAvatar)
            {
                return true;
            }
            if (activeAvatar != settlingHomeAvatar)
            {
                BeginHomeAlignmentTracking(activeAvatar);
            }
            if (!AlignHomeAvatar(activeAvatar))
            {
                return false;
            }

            RecordHomeAlignmentSample(activeAvatar.position);
            if ((homeAlignmentSampleCount >= HomeAlignmentMinimumSamples &&
                    homeAlignmentStableSampleCount >= HomeAlignmentRequiredStableSamples) ||
                homeAlignmentSampleCount >= HomeAlignmentMaximumSamples)
            {
                alignedHomeAvatar = activeAvatar;
                ResetHomeAlignmentTracking();
            }

            return true;
        }

        public static PersistentWorldMapController EnsureRuntimeMap()
        {
            if (current != null)
            {
                return current;
            }

            current = FindAnyObjectByType<PersistentWorldMapController>(
                FindObjectsInactive.Include);
            if (current != null)
            {
                return current;
            }

            GameObject prefab = Resources.Load<GameObject>(ResourceName);
            if (IsSynchronousWhitebox(prefab))
            {
                GameObject instance = Instantiate(prefab);
                instance.name = ResourceName;
                current = instance.GetComponent<PersistentWorldMapController>();
            }

            if (current == null)
            {
                var fallback = new GameObject(ResourceName);
                current = BuildDefaultMap(fallback);
                AttachPersonalSpaceVisual(current);
                Debug.Log(
                    "[MaasoWorld] initialized the synchronous neutral whitebox");
            }

            current.SetWorldActive(false);
            return current;
        }

        private static void AttachPersonalSpaceVisual(
            PersistentWorldMapController controller)
        {
            Transform visualRoot = controller?.persistentEnvironmentRoot?
                .Find("BaseVisuals/WhiteboxVisuals");
            GameObject modelPrefab = Resources.Load<GameObject>(
                PersonalSpaceResourceName);
            Material whiteMaterial = Resources.Load<Material>(
                PersonalSpaceMaterialResourceName);
            if (visualRoot == null || modelPrefab == null)
            {
                return;
            }

            GameObject model = Instantiate(modelPrefab, visualRoot, false);
            model.name = "PersonalSpaceModel";
            model.transform.SetLocalPositionAndRotation(
                Vector3.zero,
                Quaternion.identity);
            model.transform.localScale = Vector3.one;
            foreach (Collider collider in model.GetComponentsInChildren<Collider>(true))
            {
                collider.enabled = false;
            }
            if (whiteMaterial != null)
            {
                foreach (Renderer renderer in model.GetComponentsInChildren<Renderer>(true))
                {
                    Material[] materials = renderer.sharedMaterials;
                    if (materials.Length == 0)
                    {
                        renderer.sharedMaterial = whiteMaterial;
                        continue;
                    }
                    for (int materialIndex = 0;
                         materialIndex < materials.Length;
                         materialIndex++)
                    {
                        // The bundled room keeps the Blender-authored palette;
                        // the neutral resource only repairs missing slots.
                        materials[materialIndex] ??= whiteMaterial;
                    }
                    renderer.sharedMaterials = materials;
                }
            }
            for (int index = 0; index < visualRoot.childCount; index++)
            {
                Transform child = visualRoot.GetChild(index);
                if (child != model.transform)
                {
                    child.gameObject.SetActive(false);
                }
            }
        }

        private static bool IsSynchronousWhitebox(GameObject prefab)
        {
            if (prefab == null ||
                prefab.GetComponent<PersistentWorldMapController>() == null)
            {
                return false;
            }

            Transform ground = prefab.transform.Find("WorldGround");
            Transform whitebox = prefab.transform.Find(
                "PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
            Transform model = whitebox?.Find("PersonalSpaceModel");
            return ground != null &&
                Mathf.Abs(ground.localScale.x - PersonalSpaceRoomSize) <= 0.01f &&
                Mathf.Abs(ground.localScale.z - PersonalSpaceRoomSize) <= 0.01f &&
                model != null;
        }

        public void Configure(
            Transform homeAnchor,
            Transform cameraReference,
            Transform playCenter,
            IReadOnlyList<Transform> spawnAnchors,
            Transform persistentRoot,
            Transform decorationRoot,
            Collider physicalGround)
        {
            homeAgentAnchor = homeAnchor;
            homeCameraReference = cameraReference;
            worldPlayCenter = playCenter;
            persistentEnvironmentRoot = persistentRoot;
            worldDecorationRoot = decorationRoot;
            groundCollider = physicalGround;
            fallbackGroundCollider = physicalGround;
            if (spawnAnchors == null || spawnAnchors.Count == 0)
            {
                worldSpawnAnchors = System.Array.Empty<Transform>();
                return;
            }

            worldSpawnAnchors = new Transform[spawnAnchors.Count];
            for (int index = 0; index < spawnAnchors.Count; index++)
            {
                worldSpawnAnchors[index] = spawnAnchors[index];
            }
        }

        public void SetWorldActive(bool active)
        {
            worldActive = active;
            alignedHomeAvatar = null;
            ResetHomeAlignmentTracking();
            if (persistentEnvironmentRoot != null)
            {
                persistentEnvironmentRoot.gameObject.SetActive(true);
            }
            if (worldDecorationRoot != null)
            {
                worldDecorationRoot.gameObject.SetActive(active);
            }
            SetPrimitiveFallbackVisible(true);
            if (!active)
            {
                TryAlignActiveHomeAvatar();
            }
        }

        // A successful personal-room return has already placed this exact
        // selected avatar on Home's floor. Adopt that physical presentation
        // without re-grounding animated feet or reframing the final image.
        public bool AdoptReturnedHomeAvatar(Transform avatarRoot)
        {
            if(current!=this || avatarRoot==null || homeAgentAnchor==null ||
                avatarReceiver==null || avatarReceiver.ActiveAvatarRoot!=avatarRoot ||
                !avatarRoot.gameObject.activeInHierarchy ||
                avatarRoot.GetComponentInParent<WorldOwnerAvatarLease>()!=null)return false;
            Vector3 position=avatarRoot.position;
            if(float.IsNaN(position.x)||float.IsNaN(position.y)||float.IsNaN(position.z)||
                float.IsInfinity(position.x)||float.IsInfinity(position.y)||float.IsInfinity(position.z))return false;
            Vector3 planar=position-homeAgentAnchor.position;planar.y=0;
            if(planar.sqrMagnitude>.0001f || Quaternion.Angle(avatarRoot.rotation,homeAgentAnchor.rotation)>.15f)
                return false;
            worldActive=false;alignedHomeAvatar=avatarRoot;ResetHomeAlignmentTracking();
            if(persistentEnvironmentRoot!=null)persistentEnvironmentRoot.gameObject.SetActive(true);
            if(worldDecorationRoot!=null)worldDecorationRoot.gameObject.SetActive(false);
            SetPrimitiveFallbackVisible(true);
            return true;
        }

        public void ActivateBuiltInWhitebox()
        {
            groundCollider = fallbackGroundCollider;
            SetPrimitiveFallbackVisible(true);
        }

        private void BeginHomeAlignmentTracking(Transform avatarRoot)
        {
            settlingHomeAvatar = avatarRoot;
            lastHomeAlignmentPosition = Vector3.zero;
            homeAlignmentSampleCount = 0;
            homeAlignmentStableSampleCount = 0;
            hasLastHomeAlignmentPosition = false;
        }

        private void RecordHomeAlignmentSample(Vector3 position)
        {
            homeAlignmentSampleCount++;
            if (hasLastHomeAlignmentPosition &&
                (position - lastHomeAlignmentPosition).sqrMagnitude <=
                    HomeAlignmentPositionEpsilon * HomeAlignmentPositionEpsilon)
            {
                homeAlignmentStableSampleCount++;
            }
            else
            {
                homeAlignmentStableSampleCount = 0;
            }

            lastHomeAlignmentPosition = position;
            hasLastHomeAlignmentPosition = true;
        }

        private void ResetHomeAlignmentTracking()
        {
            settlingHomeAvatar = null;
            lastHomeAlignmentPosition = Vector3.zero;
            homeAlignmentSampleCount = 0;
            homeAlignmentStableSampleCount = 0;
            hasLastHomeAlignmentPosition = false;
        }

        public void RegisterPersistentEnvironment(Transform environmentRoot)
        {
            if (environmentRoot == null ||
                persistentEnvironmentRoot == null ||
                environmentRoot == persistentEnvironmentRoot)
            {
                return;
            }

            persistentEnvironmentRoot.gameObject.SetActive(true);
            if (registeredPersistentEnvironment == environmentRoot)
            {
                if (environmentRoot.parent != persistentEnvironmentRoot)
                {
                    environmentRoot.SetParent(persistentEnvironmentRoot, false);
                }
                RegisterEnvironmentGround(environmentRoot);
                return;
            }

            if (registeredPersistentEnvironment != null &&
                registeredPersistentEnvironment.parent == persistentEnvironmentRoot)
            {
                registeredPersistentEnvironment.SetParent(null, true);
            }
            registeredPersistentEnvironment = environmentRoot;
            registeredPersistentEnvironment.SetParent(persistentEnvironmentRoot, false);
            RegisterEnvironmentGround(registeredPersistentEnvironment);
        }

        public void SetPrimitiveFallbackVisible(bool visible)
        {
            fallbackGroundCollider ??= groundCollider;
            SetFallbackChildVisible("BaseVisuals", visible);
            SetFallbackChildVisible("EnvironmentProps", visible);
            if (fallbackGroundCollider == null)
            {
                return;
            }
            Renderer[] groundRenderers =
                fallbackGroundCollider.GetComponents<Renderer>();
            Transform authoredModel = persistentEnvironmentRoot?.Find(
                "BaseVisuals/WhiteboxVisuals/PersonalSpaceModel");
            bool hasAuthoredFloor = authoredModel != null &&
                authoredModel.gameObject.activeInHierarchy &&
                authoredModel.GetComponentInChildren<Renderer>() != null;
            for (int index = 0; index < groundRenderers.Length; index++)
            {
                // Its top face shares Y=0 with the baked oak floor. Keep the
                // authoritative collider but never draw both coplanar meshes.
                groundRenderers[index].enabled = visible && !hasAuthoredFloor;
            }
            fallbackGroundCollider.gameObject.SetActive(true);
            fallbackGroundCollider.enabled = visible;
            if (visible)
            {
                groundCollider = fallbackGroundCollider;
            }
        }

        public Vector3 ProjectToGround(Vector3 worldPosition)
        {
            Collider walkingSurface = GroundCollider;
            if (walkingSurface == null || !walkingSurface.enabled)
            {
                worldPosition.y = GroundY;
                return worldPosition;
            }

            Bounds bounds = walkingSurface.bounds;
            float rayStartY = Mathf.Max(
                worldPosition.y,
                bounds.max.y + 2f);
            var ray = new Ray(
                new Vector3(worldPosition.x, rayStartY, worldPosition.z),
                Vector3.down);
            float maxDistance = Mathf.Max(
                4f,
                rayStartY - bounds.min.y + 2f);
            if (walkingSurface.Raycast(ray, out RaycastHit hit, maxDistance))
            {
                worldPosition.y = hit.point.y;
                return worldPosition;
            }

            worldPosition.y = GroundY;
            return worldPosition;
        }

        public static Vector3 ProjectToActiveGround(Vector3 worldPosition)
        {
            if (current != null)
            {
                return current.ProjectToGround(worldPosition);
            }

            worldPosition.y = GroundY;
            return worldPosition;
        }

        private void RegisterEnvironmentGround(Transform environmentRoot)
        {
            TerrainCollider terrain =
                environmentRoot.GetComponentInChildren<TerrainCollider>(true);
            if (terrain == null || terrain.terrainData == null)
            {
                return;
            }

            terrain.gameObject.SetActive(true);
            terrain.enabled = true;
            groundCollider = terrain;
        }

        private void SetFallbackChildVisible(string childName, bool visible)
        {
            Transform child = persistentEnvironmentRoot?.Find(childName);
            if (child != null)
            {
                child.gameObject.SetActive(visible);
            }
        }

        public bool AlignHomeAvatar(Transform avatarRoot)
        {
            if (avatarRoot == null || homeAgentAnchor == null)
            {
                return false;
            }

            FrontFullBodyCamera homeFraming = null;
            FrontFullBodyCamera[] framings = FindObjectsByType<FrontFullBodyCamera>(
                FindObjectsInactive.Include,
                FindObjectsSortMode.None);
            for (int index = 0; index < framings.Length; index++)
            {
                FrontFullBodyCamera framing = framings[index];
                if (framing != null && framing.TargetRoot == avatarRoot)
                {
                    homeFraming = framing;
                    // Hidden local meshes cannot be grounded yet. Their
                    // preparation frame still needs this room's camera limits.
                    homeFraming.SetHomeViewReference(homeCameraReference);
                    break;
                }
            }
            Vector3 previousAvatarPosition = avatarRoot.position;
            avatarRoot.SetPositionAndRotation(
                homeAgentAnchor.position,
                homeAgentAnchor.rotation);
            bool aligned = WorldAvatarGrounding.TryGround(
                avatarRoot,
                GroundY,
                out _);
            if (aligned && homeFraming != null)
            {
                homeFraming.transform.position +=
                    avatarRoot.position - previousAvatarPosition;
                homeFraming.TargetRoot = avatarRoot;
                homeFraming.FrameNow();
            }
            if (aligned &&
                avatarReceiver != null &&
                avatarReceiver.ActiveAvatarRoot == avatarRoot)
            {
                avatarReceiver.RebaseActiveAvatarRootPose();
            }
            return aligned;
        }

        public static PersistentWorldMapController BuildDefaultMap(GameObject root)
        {
            PersistentWorldMapController controller =
                root.GetComponent<PersistentWorldMapController>() ??
                root.AddComponent<PersistentWorldMapController>();

            Transform ground = CreatePrimitive(
                PrimitiveType.Cube,
                "WorldGround",
                root.transform,
                new Vector3(0f, -0.05f, 0f),
                new Vector3(PersonalSpaceRoomSize, 0.1f, PersonalSpaceRoomSize),
                null,
                new Color(0.78f, 0.77f, 0.74f),
                true);

            Transform persistentRoot = CreateAnchor(
                "PersistentEnvironmentRoot",
                root.transform,
                Vector3.zero);
            Transform decorationRoot = CreateAnchor(
                "WorldDecorationRoot",
                root.transform,
                Vector3.zero);
            Transform visualRoot = CreateAnchor("BaseVisuals", persistentRoot, Vector3.zero);
            CreateAnchor(
                "WhiteboxVisuals",
                visualRoot,
                Vector3.zero);
            CreateAnchor("EnvironmentProps", persistentRoot, Vector3.zero);

            Transform homeAnchor = CreateAnchor("HomeAgentAnchor", root.transform, Vector3.zero);
            homeAnchor.localRotation = Quaternion.identity;
            Transform cameraReference = CreateAnchor(
                "HomeCameraReference",
                root.transform,
                new Vector3(0f, 0.85f, 3.2f));
            cameraReference.localRotation = Quaternion.Euler(0f, 180f, 0f);
            Transform playCenter = CreateAnchor("WorldPlayCenter", root.transform, Vector3.zero);
            Transform spawnRoot = CreateAnchor("WorldSpawnAnchors", root.transform, Vector3.zero);
            var spawns = new List<Transform>();
            for (int index = 0; index < 8; index++)
            {
                float radians = (Mathf.PI * 2f * index) / 8f;
                Vector3 position = new(
                    Mathf.Sin(radians) * PersonalSpaceSpawnRadius,
                    GroundY,
                    Mathf.Cos(radians) * PersonalSpaceSpawnRadius);
                Transform spawn = CreateAnchor($"Spawn-{index + 1}", spawnRoot, position);
                spawn.localRotation = Quaternion.LookRotation(-position.normalized, Vector3.up);
                spawns.Add(spawn);
            }

            controller.Configure(
                homeAnchor,
                cameraReference,
                playCenter,
                spawns,
                persistentRoot,
                decorationRoot,
                ground.GetComponent<Collider>());
            return controller;
        }

        private static Transform CreatePrimitive(
            PrimitiveType type,
            string name,
            Transform parent,
            Vector3 position,
            Vector3 scale,
            Material material,
            Color fallbackColor,
            bool keepCollider)
        {
            GameObject value = GameObject.CreatePrimitive(type);
            value.name = name;
            value.transform.SetParent(parent, false);
            value.transform.localPosition = position;
            value.transform.localScale = scale;
            Renderer renderer = value.GetComponent<Renderer>();
            if (renderer != null)
            {
                if (material != null)
                {
                    renderer.sharedMaterial = material;
                }
                else
                {
                    var properties = new MaterialPropertyBlock();
                    properties.SetColor("_Color", fallbackColor);
                    properties.SetColor("_BaseColor", fallbackColor);
                    renderer.SetPropertyBlock(properties);
                }
            }
            if (!keepCollider)
            {
                Collider collider = value.GetComponent<Collider>();
                if (collider != null)
                {
                    if (Application.isPlaying)
                    {
                        Destroy(collider);
                    }
                    else
                    {
                        DestroyImmediate(collider);
                    }
                }
            }
            return value.transform;
        }

        private static Transform CreateAnchor(
            string name,
            Transform parent,
            Vector3 position)
        {
            var anchor = new GameObject(name).transform;
            anchor.SetParent(parent, false);
            anchor.localPosition = position;
            return anchor;
        }
    }
}
