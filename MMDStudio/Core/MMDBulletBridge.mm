//
//  MMDBulletBridge.mm
//  Thin C++ layer around Bullet. Nothing here knows about PMX or bones; the
//  Swift side owns that mapping. Keeping this file dumb is the point: it is
//  the only place that has to agree with Bullet's headers.
//

#import "MMDBulletBridge.h"

#include <btBulletDynamicsCommon.h>

#include <vector>

struct MMDPhysWorld {
    btDefaultCollisionConfiguration *config = nullptr;
    btCollisionDispatcher *dispatcher = nullptr;
    btBroadphaseInterface *broadphase = nullptr;
    btSequentialImpulseConstraintSolver *solver = nullptr;
    btDiscreteDynamicsWorld *world = nullptr;

    std::vector<btCollisionShape *> shapes;
    std::vector<btRigidBody *> bodies;
    std::vector<btTypedConstraint *> joints;
};

static inline btVector3 toVec(const float v[3]) {
    return btVector3(v[0], v[1], v[2]);
}

static inline btQuaternion toQuat(const float q[4]) {
    // PMX / Swift give (x, y, z, w); keep that order, Bullet takes it as is.
    return btQuaternion(q[0], q[1], q[2], q[3]);
}

static inline void fromTransform(const btTransform &t, float pos[3], float rot[4]) {
    const btVector3 p = t.getOrigin();
    const btQuaternion q = t.getRotation();
    pos[0] = p.x(); pos[1] = p.y(); pos[2] = p.z();
    rot[0] = q.x(); rot[1] = q.y(); rot[2] = q.z(); rot[3] = q.w();
}

extern "C" {

MMDPhysWorld *MMDPhysWorldCreate(float gravityY) {
    auto *w = new MMDPhysWorld();
    w->config = new btDefaultCollisionConfiguration();
    w->dispatcher = new btCollisionDispatcher(w->config);
    w->broadphase = new btDbvtBroadphase();
    w->solver = new btSequentialImpulseConstraintSolver();
    w->world = new btDiscreteDynamicsWorld(w->dispatcher, w->broadphase,
                                           w->solver, w->config);
    w->world->setGravity(btVector3(0.0f, gravityY, 0.0f));
    return w;
}

void MMDPhysWorldDestroy(MMDPhysWorld *w) {
    if (!w) { return; }
    MMDPhysWorldClear(w);
    delete w->world;
    delete w->solver;
    delete w->broadphase;
    delete w->dispatcher;
    delete w->config;
    delete w;
}

void MMDPhysWorldClear(MMDPhysWorld *w) {
    if (!w) { return; }
    for (auto *c : w->joints) {
        w->world->removeConstraint(c);
        delete c;
    }
    w->joints.clear();
    for (auto *b : w->bodies) {
        w->world->removeRigidBody(b);
        delete b;
    }
    w->bodies.clear();
    for (auto *s : w->shapes) { delete s; }
    w->shapes.clear();
}

int32_t MMDPhysAddBody(MMDPhysWorld *w,
                       int shapeKind, const float size[3],
                       int boneIndex, int32_t group, int32_t mask,
                       float mass, float linearDamping, float angularDamping,
                       float restitution, float friction,
                       const float position[3], const float rotation[4]) {
    if (!w) { return -1; }
    (void)boneIndex;

    btCollisionShape *shape = nullptr;
    switch (shapeKind) {
        case 1:
            // PMX box size is a half extent on each axis.
            shape = new btBoxShape(btVector3(btFabs(size[0]), btFabs(size[1]), btFabs(size[2])));
            break;
        case 2:
            // PMX capsule: x is the radius, y the height of the cylinder part.
            shape = new btCapsuleShape(btFabs(size[0]), btFabs(size[1]));
            break;
        default:
            shape = new btSphereShape(btFabs(size[0]));
            break;
    }
    if (shape->getMargin() > 0.04f) { shape->setMargin(0.04f); }
    w->shapes.push_back(shape);

    const bool kinematic = mass <= 0.0f;
    btVector3 inertia(0, 0, 0);
    if (!kinematic) { shape->calculateLocalInertia(mass, inertia); }

    btRigidBody::btRigidBodyConstructionInfo info(kinematic ? 0.0f : mass, nullptr, shape, inertia);
    info.m_linearDamping = linearDamping;
    info.m_angularDamping = angularDamping;
    info.m_restitution = restitution;
    info.m_friction = friction;

    auto *body = new btRigidBody(info);
    const btTransform initial(toQuat(rotation), toVec(position));
    body->setWorldTransform(initial);
    body->setInterpolationWorldTransform(initial);
    if (kinematic) {
        body->setCollisionFlags(body->getCollisionFlags() | btCollisionObject::CF_KINEMATIC_OBJECT);
    }
    // Hair that settles must not fall asleep, otherwise the strand freezes in
    // whatever pose it happened to hold when the solver idled it out.
    body->setActivationState(DISABLE_DEACTIVATION);

    w->world->addRigidBody(body, group, mask);
    w->bodies.push_back(body);
    return (int32_t)w->bodies.size() - 1;
}

int32_t MMDPhysBodyCount(MMDPhysWorld *w) {
    return w ? (int32_t)w->bodies.size() : 0;
}

void MMDPhysSetBodyKinematic(MMDPhysWorld *w, int32_t index, int kinematic) {
    if (!w || index < 0 || index >= (int32_t)w->bodies.size()) { return; }
    btRigidBody *body = w->bodies[(size_t)index];
    int flags = body->getCollisionFlags();
    if (kinematic) {
        flags |= btCollisionObject::CF_KINEMATIC_OBJECT;
        body->setMassProps(0.0f, btVector3(0, 0, 0));
    } else {
        flags &= ~btCollisionObject::CF_KINEMATIC_OBJECT;
    }
    body->setCollisionFlags(flags);
    body->activate(true);
}

void MMDPhysSetBodyTransform(MMDPhysWorld *w, int32_t index,
                             const float position[3], const float rotation[4]) {
    if (!w || index < 0 || index >= (int32_t)w->bodies.size()) { return; }
    btRigidBody *body = w->bodies[(size_t)index];
    const btTransform t(toQuat(rotation), toVec(position));
    // Both the current and the previous transform: Bullet derives a kinematic
    // body's velocity from the delta, and leaving the interpolation transform
    // behind would make it shoot across the scene on the next step.
    body->setWorldTransform(t);
    body->setInterpolationWorldTransform(t);
}

void MMDPhysGetBodyTransform(MMDPhysWorld *w, int32_t index,
                             float position[3], float rotation[4]) {
    if (!w || index < 0 || index >= (int32_t)w->bodies.size()) {
        position[0] = position[1] = position[2] = 0.0f;
        rotation[0] = rotation[1] = rotation[2] = 0.0f;
        rotation[3] = 1.0f;
        return;
    }
    fromTransform(w->bodies[(size_t)index]->getWorldTransform(), position, rotation);
}

void MMDPhysResetBody(MMDPhysWorld *w, int32_t index) {
    if (!w || index < 0 || index >= (int32_t)w->bodies.size()) { return; }
    btRigidBody *body = w->bodies[(size_t)index];
    body->setLinearVelocity(btVector3(0, 0, 0));
    body->setAngularVelocity(btVector3(0, 0, 0));
    body->clearForces();
    body->setInterpolationWorldTransform(body->getWorldTransform());
}

int32_t MMDPhysAdd6DofJoint(MMDPhysWorld *w, int32_t bodyA, int32_t bodyB,
                            const float frameA[3], const float rotA[4],
                            const float frameB[3], const float rotB[4],
                            const float linearLower[3], const float linearUpper[3],
                            const float angularLower[3], const float angularUpper[3],
                            const float springLinear[3], const float springAngular[3]) {
    if (!w) { return -1; }
    const int32_t count = (int32_t)w->bodies.size();
    if (bodyB < 0 || bodyB >= count) { return -1; }
    if (bodyA >= count) { bodyA = -1; }

    // Frames arrive already expressed in each body's local space, so the
    // caller does the inverse-transform once and this stays a straight map.
    const btTransform frameInA(toQuat(rotA), toVec(frameA));
    const btTransform frameInB(toQuat(rotB), toVec(frameB));

    btGeneric6DofSpringConstraint *c = nullptr;
    if (bodyA >= 0) {
        c = new btGeneric6DofSpringConstraint(*w->bodies[(size_t)bodyA],
                                              *w->bodies[(size_t)bodyB],
                                              frameInA, frameInB, true);
    } else {
        // Jointed to the world: the single-body overload anchors to a fixed
        // frame. PMX uses this for "this strand only hangs, nothing pushes".
        c = new btGeneric6DofSpringConstraint(*w->bodies[(size_t)bodyB],
                                              frameInB, true);
    }

    c->setLinearLowerLimit(toVec(linearLower));
    c->setLinearUpperLimit(toVec(linearUpper));
    c->setAngularLowerLimit(toVec(angularLower));
    c->setAngularUpperLimit(toVec(angularUpper));

    for (int i = 0; i < 3; ++i) {
        const float s = springLinear[i];
        c->enableSpring(i, s > 0.0f);
        if (s > 0.0f) {
            c->setStiffness(i, s);
            c->setDamping(i, 0.5f);
        }
    }
    for (int i = 0; i < 3; ++i) {
        const float s = springAngular[i];
        c->enableSpring(i + 3, s > 0.0f);
        if (s > 0.0f) {
            c->setStiffness(i + 3, s);
            c->setDamping(i + 3, 0.5f);
        }
    }

    w->world->addConstraint(c, true);
    w->joints.push_back(c);
    return (int32_t)w->joints.size() - 1;
}

int32_t MMDPhysJointCount(MMDPhysWorld *w) {
    return w ? (int32_t)w->joints.size() : 0;
}

void MMDPhysWorldStep(MMDPhysWorld *w, float dt, int maxSubSteps, float fixedTimeStep) {
    if (!w || dt <= 0.0f) { return; }
    w->world->stepSimulation(dt, maxSubSteps, fixedTimeStep);
}

} // extern "C"
