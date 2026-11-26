import CoreVideo
import Foundation
import ImageIO
import Vision

enum NativeHandPose {
    struct Sample {
        let wrist: CGPoint
        let palm: CGPoint
        let fingers: [Finger]
    }

    struct Finger {
        let tip: CGPoint
        let joint: CGPoint
    }

    struct Body {
        let leftShoulder: CGPoint
        let rightShoulder: CGPoint
        let nose: CGPoint
    }

    static func isRaised(_ hand: Sample, beside body: Body) -> Bool {
        let left = min(body.leftShoulder.x, body.rightShoulder.x)
        let right = max(body.leftShoulder.x, body.rightShoulder.x)
        let width = right - left
        guard width >= 0.08, hand.fingers.count == 4,
              hand.palm.x < left - width * 0.07 || hand.palm.x > right + width * 0.07,
              hand.palm.y > (body.leftShoulder.y + body.rightShoulder.y) / 2,
              distance(hand.palm, body.nose) >= width * 0.42 else { return false }
        return hand.fingers.allSatisfy {
            $0.tip.y > $0.joint.y
                && distance($0.tip, hand.wrist) > distance($0.joint, hand.wrist) * 1.1
        }
    }

    static func detect(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Bool {
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        let bodies = VNDetectHumanBodyPoseRequest()
        let request = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        guard (try? request.perform([hands, bodies])) != nil,
              let detected = hands.results, detected.count == 1, let hand = detected.first,
              let people = bodies.results, people.count == 1, let person = people.first,
              let sample = sample(hand), let body = body(person) else { return false }
        return isRaised(sample, beside: body)
    }

    private static func sample(_ hand: VNHumanHandPoseObservation) -> Sample? {
        guard let wrist = point(try? hand.recognizedPoint(.wrist)),
              let center = point(try? hand.recognizedPoint(.middleMCP)) else { return nil }
        let joints: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)
        ]
        let fingers = joints.compactMap { tip, joint -> Finger? in
            guard let tip = point(try? hand.recognizedPoint(tip)),
                  let joint = point(try? hand.recognizedPoint(joint)) else { return nil }
            return Finger(tip: tip, joint: joint)
        }
        return Sample(
            wrist: wrist, palm: CGPoint(x: (wrist.x + center.x) / 2, y: (wrist.y + center.y) / 2),
            fingers: fingers
        )
    }

    private static func body(_ person: VNHumanBodyPoseObservation) -> Body? {
        guard let left = point(try? person.recognizedPoint(.leftShoulder)),
              let right = point(try? person.recognizedPoint(.rightShoulder)),
              let nose = point(try? person.recognizedPoint(.nose)) else { return nil }
        return Body(leftShoulder: left, rightShoulder: right, nose: nose)
    }

    private static func point(_ observation: VNRecognizedPoint?) -> CGPoint? {
        guard let observation, observation.confidence >= 0.65 else { return nil }
        return observation.location
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
