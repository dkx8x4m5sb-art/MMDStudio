//
//  MMDBulletBridge.h
//  C surface over Bullet so Swift can drive it through the bridging header.
//
//  Only what PMX actually expresses is exposed: sphere / box / capsule rigid
//  bodies, 6DOF spring joints, and a fixed-step world. No soft bodies, no
//  vehicles, no character controller — the dynamics build only contains the
//  pieces a bone chain needs.
//

#ifndef MMDBulletBridge_h
#define MMDBulletBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MMDPhysWorld MMDPhysWorld;

/// Creates a world with `gravityY` (MMD unit: negative and large, PMX numbers
/// are authored against about -98).
MMDPhysWorld *MMDPhysWorldCreate(float gravityY);
void MMDPhysWorldDestroy(MMDPhysWorld *world);

/// Drops every body and joint but keeps the world reusable.
void MMDPhysWorldClear(MMDPhysWorld *world);

/// Advances by `dt`, internally split into `maxSubSteps` of `fixedTimeStep`.
void MMDPhysWorldStep(MMDPhysWorld *world, float dt, int maxSubSteps, float fixedTimeStep);

/// shapeKind: 0 sphere, 1 box, 2 capsule. `size` is the PMX triple:
/// sphere = (radius, 0, 0), box = half extents, capsule = (radius, cylinder
/// height along Y, 0). Returns the body index, or -1.
int32_t MMDPhysAddBody(MMDPhysWorld *world,
                       int shapeKind, const float size[3],
                       int boneIndex, int32_t group, int32_t mask,
                       float mass, float linearDamping, float angularDamping,
                       float restitution, float friction,
                       const float position[3], const float rotation[4]);

int32_t MMDPhysBodyCount(MMDPhysWorld *world);

/// Kinematic bodies follow their bone instead of being simulated.
void MMDPhysSetBodyKinematic(MMDPhysWorld *world, int32_t index, int kinematic);

void MMDPhysSetBodyTransform(MMDPhysWorld *world, int32_t index,
                             const float position[3], const float rotation[4]);
void MMDPhysGetBodyTransform(MMDPhysWorld *world, int32_t index,
                             float position[3], float rotation[4]);

/// Parks a body until the next SetBodyTransform, so a teleport or a seek does
/// not hand the solver a hundred units per step of velocity.
void MMDPhysResetBody(MMDPhysWorld *world, int32_t index);

int32_t MMDPhysAdd6DofJoint(MMDPhysWorld *world, int32_t bodyA, int32_t bodyB,
                            const float frameA[3], const float rotA[4],
                            const float frameB[3], const float rotB[4],
                            const float linearLower[3], const float linearUpper[3],
                            const float angularLower[3], const float angularUpper[3],
                            const float springLinear[3], const float springAngular[3]);

int32_t MMDPhysJointCount(MMDPhysWorld *world);

#ifdef __cplusplus
}
#endif

#endif /* MMDBulletBridge_h */
