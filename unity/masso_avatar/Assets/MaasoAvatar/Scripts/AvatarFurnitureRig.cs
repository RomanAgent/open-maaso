using System;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class AvatarFurnitureAnchor
    {
        public string Id;
        public Transform Seat;
        public Transform Approach;
        public Transform Lying;
        public Transform WorkSurface;
        public Transform[] Waypoints;
        public bool CanLie;
        public bool HasMeasuredSupport;
        public float SeatSupportY,LyingSupportY,FootFloorY;
    }

    /// <summary>Reviewed scene-local anchors. Never reused across a map swap.</summary>
    public sealed class AvatarFurnitureRig : MonoBehaviour
    {
        public AvatarFurnitureAnchor[] Anchors = Array.Empty<AvatarFurnitureAnchor>();
        public string SceneKey = "coastal_v2";
        public PersonalSpaceNavigation Navigation;
        public string SceneId => SceneKey + ":" + gameObject.GetEntityId();
        private Transform occupant;
        private AvatarDeskWorkLayout deskLayout;
        private void Awake() { EnsureDeskWorkLayout(); }
        public bool HasDeskKeyboard => deskLayout?.Ready == true;
        public Bounds DeskKeyboardBounds => HasDeskKeyboard ? deskLayout.KeyboardBounds : default;
        public bool EnsureDeskWorkLayout()
        {
            if (SceneKey != "coastal_v4") return false;
            deskLayout ??= new AvatarDeskWorkLayout(this);
            return deskLayout.Align();
        }
        private void OnDestroy() { deskLayout?.Dispose(); deskLayout = null; }
        public AvatarFurnitureAnchor Find(string id) => Array.Find(Anchors, a => a.Id == id);
        public bool TryOccupy(Transform actor) { if (occupant != null && occupant != actor) return false; occupant = actor; return true; }
        public void Release(Transform actor) { if (occupant == actor) occupant = null; }

        public static AvatarFurnitureRig Ensure(PersistentWorldMapController map)
        {
            Transform environment = map != null ? map.PersistentEnvironmentRoot : null;
            if (environment == null || !environment.gameObject.activeInHierarchy) return null;
            var layouts=environment.GetComponentsInChildren<PersonalSpaceNavigation>();
            if(layouts.Length>0)
            {
                if(layouts.Length!=1 || string.IsNullOrWhiteSpace(layouts[0].Revision)) return null;
                var bound=layouts[0].GetComponent<AvatarFurnitureRig>();
                return bound!=null && bound.Navigation==layouts[0] ? bound : null;
            }
            // Other maps must provide their own authored anchors. Retired V2
            // fixtures are editor-only and never supply a runtime fallback.
            return environment.GetComponentInChildren<AvatarFurnitureRig>();
        }
    }
}
