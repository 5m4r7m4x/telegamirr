import AudioBlob
import AvatarNode
import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import SolidRoundedButtonNode
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import TelegramAudio
import AccountContext
import LocalizedPeerData
import PhotoResources
import ReplayKit
import CallsEmoji
import TooltipUI
import AlertUI
import PresentationDataUtils
import DeviceAccess
import ContextUI
import GradientBackground

final class CallControllerView: ViewControllerTracingNodeView {

    private enum VideoNodeCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private enum UIState {
        case ringing
        case active
        case weakSignal
        case video
        case videoPreview
    }

    private enum PictureInPictureGestureState {
        case none
        case collapsing(didSelectCorner: Bool)
        case dragging(initialPosition: CGPoint, draggingPosition: CGPoint)
    }

    var toggleMute: (() -> Void)?
    var setCurrentAudioOutput: ((AudioSessionOutput) -> Void)?
    var beginAudioOuputSelection: ((Bool) -> Void)?
    var acceptCall: (() -> Void)?
    var endCall: (() -> Void)?
    var back: (() -> Void)?
    var presentCallRating: ((CallId, Bool) -> Void)?
    var callEnded: ((Bool) -> Void)?
    var dismissedInteractively: (() -> Void)?
    var present: ((ViewController) -> Void)?
    var dismissAllTooltips: (() -> Void)?

    var isMuted: Bool = false {
        didSet {
            self.buttonsView.isMuted = self.isMuted
            self.updateToastContent()
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
    }
    
    private let sharedContext: SharedAccountContext
    private let accountContext: AccountContext
    private let account: Account
    
    private let statusBar: StatusBar
    
    private var presentationData: PresentationData
    private var peer: Peer?
    private let debugInfo: Signal<(String, String), NoError>
    private var forceReportRating = false
    private let easyDebugAccess: Bool
    private let call: PresentationCall
    
    private let containerTransformationView: UIView
    private let contentContainerView: UIView
    private let videoContainerNode: PinchSourceContainerView

    private var gradientBackgroundNode: GradientBackgroundNode
    private let dimNode: ASImageNode // TODO: implement - remove?
    
    private var candidateIncomingVideoNodeValue: CallVideoView?
    private var incomingVideoNodeValue: CallVideoView?
    private var outgoingVideoView: CallVideoView?
    private var outgoingVideoPreviewContainer: UIView?
    private var removedOutgoingVideoPreviewContainer: UIView?
    private var candidateOutgoingVideoPreviewView: CallVideoView?
    private var outgoingVideoPreviewView: CallVideoView?
    private var cancelOutgoingVideoPreviewButtonNode: HighlightableButtonNode?
    private var outgoingVideoPreviewDoneButton: SolidRoundedButtonNode?
    private var outgoingVideoPreviewWheelNode: WheelControlNodeNew?
    private var outgoingVideoPreviewBroadcastPickerView: UIView?

    private var outgoingVideoPreviewPlaceholderTextNode: ImmediateTextNode?
    private var outgoingVideoPreviewPlaceholderIconNode: ASImageNode?

    private var incomingVideoViewRequested: Bool = false
    private var outgoingVideoViewRequested: Bool = false
    
    private var removedMinimizedVideoNodeValue: CallVideoView?
    private var removedExpandedVideoNodeValue: CallVideoView?
    
    private var isRequestingVideo: Bool = false
    private var animateIncomingVideoPreviewContainerOnce: Bool = false
    private var animateOutgoingVideoPreviewContainerOnce: Bool = false
    
    private var hiddenUIForActiveVideoCallOnce: Bool = false
    private var hideUIForActiveVideoCallTimer: SwiftSignalKit.Timer?
    
    private var displayedCameraConfirmation: Bool = false
    private var displayedCameraTooltip: Bool = false
        
    private var expandedVideoNode: CallVideoView?
    private var minimizedVideoNode: CallVideoView?
    private var disableAnimationForExpandedVideoOnce: Bool = false
    private var animationForExpandedVideoSnapshotView: UIView? = nil
    
    private var outgoingVideoNodeCorner: VideoNodeCorner = .bottomRight
    private let backButtonArrowNode: ASImageNode
    private let backButtonNode: HighlightableButtonNode
    private let avatarNode: AvatarNode
    private let audioLevelView: VoiceBlobView
    private let statusNode: CallControllerStatusView
    private let toastNode: CallControllerToastContainerNode
    private let buttonsView: CallControllerButtonsView
    private var keyPreviewNode: CallControllerKeyPreviewView?
    
    private var debugNode: CallDebugNode?
    
    private var keyTextData: (Data, String)?
    private let keyButtonNode: CallControllerKeyButton
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    private var disableActionsUntilTimestamp: Double = 0.0

    private var uiState: UIState?
    private var buttonsTerminationMode: CallControllerButtonsMode?
    private var debugTapCounter: (Double, Int) = (0.0, 0)
    private var minimizedVideoInitialPosition: CGPoint?
    private var minimizedVideoDraggingPosition: CGPoint?
    private var displayedVersionOutdatedAlert: Bool = false
    private var shouldStayHiddenUntilConnection: Bool = false
    private var audioOutputState: ([AudioSessionOutput], currentOutput: AudioSessionOutput?)?
    private var callState: PresentationCallState?
    private var toastContent: CallControllerToastContent?
    private var displayToastsAfterTimestamp: Double?
    private var buttonsMode: CallControllerButtonsMode?
    private var isUIHidden: Bool = false
    private var isVideoPaused: Bool = false
    private var isVideoPinched: Bool = false
    private var pictureInPictureGestureState: PictureInPictureGestureState = .none
    private var pictureInPictureCorner: VideoNodeCorner = .topRight
    private var pictureInPictureTransitionFraction: CGFloat = 0.0
    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var orientationDidChangeObserver: NSObjectProtocol?
    private var currentRequestedAspect: CGFloat?
    private var outgoingVideoPreviewWheelSelectedTabIndex: Int = 1

    private var hasVideoNodes: Bool {
        return self.expandedVideoNode != nil || self.minimizedVideoNode != nil
    }

    // MARK: - Initialization
    
    init(sharedContext: SharedAccountContext,
         accountContext: AccountContext,
         account: Account,
         presentationData: PresentationData,
         statusBar: StatusBar,
         debugInfo: Signal<(String, String), NoError>,
         shouldStayHiddenUntilConnection: Bool = false,
         easyDebugAccess: Bool,
         call: PresentationCall) {
        self.sharedContext = sharedContext
        self.accountContext = accountContext
        self.account = account
        self.presentationData = presentationData
        self.statusBar = statusBar
        self.debugInfo = debugInfo
        self.shouldStayHiddenUntilConnection = shouldStayHiddenUntilConnection
        self.easyDebugAccess = easyDebugAccess
        self.call = call
        
        self.containerTransformationView = UIView()
        self.containerTransformationView.clipsToBounds = true
        
        self.contentContainerView = UIView()
        
        self.videoContainerNode = PinchSourceContainerView()

        self.gradientBackgroundNode = createGradientBackgroundNode()

        self.dimNode = ASImageNode()
        self.dimNode.contentMode = .scaleToFill
        self.dimNode.isUserInteractionEnabled = false
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.3)
        
        self.backButtonArrowNode = ASImageNode()
        self.backButtonArrowNode.displayWithoutProcessing = true
        self.backButtonArrowNode.displaysAsynchronously = false
        self.backButtonArrowNode.image = NavigationBarTheme.generateBackArrowImage(color: .white)
        self.backButtonNode = HighlightableButtonNode()

        let avatarWidth: CGFloat = 136.0
        let avatarFrame = CGRect(x: 0, y: 0, width: avatarWidth, height: avatarWidth)
        let avatarFont = avatarPlaceholderFont(size: floor(avatarWidth * 16.0 / 37.0))
        self.avatarNode = AvatarNode(font: avatarFont)
        self.avatarNode.frame = avatarFrame
        self.avatarNode.cornerRadius = avatarWidth / 2.0
        self.avatarNode.clipsToBounds = true
        self.audioLevelView = VoiceBlobView(frame: avatarFrame,
                                            maxLevel: 4,
                                            smallBlobRange: (1.05, 0.15),
                                            mediumBlobRange: (1.12, 1.47),
                                            bigBlobRange: (1.17, 1.6)
        )
        self.audioLevelView.setColor(UIColor(rgb: 0xFFFFFF))

        self.statusNode = CallControllerStatusView()
        
        self.buttonsView = CallControllerButtonsView(strings: self.presentationData.strings)
        self.toastNode = CallControllerToastContainerNode(strings: self.presentationData.strings)
        self.keyButtonNode = CallControllerKeyButton()
        self.keyButtonNode.accessibilityElementsHidden = false
        
        super.init(frame: CGRect.zero)
        
        self.contentContainerView.backgroundColor = .black
        
        self.addSubview(self.containerTransformationView)
        self.containerTransformationView.addSubview(self.contentContainerView)
        
        self.backButtonNode.setTitle(presentationData.strings.Common_Back, with: Font.regular(17.0), with: .white, for: [])
        self.backButtonNode.accessibilityLabel = presentationData.strings.Call_VoiceOver_Minimize
        self.backButtonNode.accessibilityTraits = [.button]
        self.backButtonNode.hitTestSlop = UIEdgeInsets(top: -8.0, left: -20.0, bottom: -8.0, right: -8.0)
        self.backButtonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.backButtonNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonArrowNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonNode.alpha = 0.4
                    strongSelf.backButtonArrowNode.alpha = 0.4
                } else {
                    strongSelf.backButtonNode.alpha = 1.0
                    strongSelf.backButtonArrowNode.alpha = 1.0
                    strongSelf.backButtonNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                    strongSelf.backButtonArrowNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        self.contentContainerView.addSubnode(self.gradientBackgroundNode)
        self.contentContainerView.addSubview(self.videoContainerNode)
        self.contentContainerView.addSubnode(self.dimNode)
        self.contentContainerView.addSubview(self.audioLevelView)
        self.contentContainerView.addSubnode(self.avatarNode)
        self.contentContainerView.addSubview(self.statusNode)
        self.contentContainerView.addSubview(self.buttonsView)
        self.contentContainerView.addSubnode(self.toastNode)
        self.contentContainerView.addSubnode(self.keyButtonNode)
        self.contentContainerView.addSubnode(self.backButtonArrowNode)
        self.contentContainerView.addSubnode(self.backButtonNode)

        let panRecognizer = CallPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.shouldBegin = { [weak self] _ in
            guard let strongSelf = self else {
                return false
            }
            if strongSelf.areUserActionsDisabledNow() {
                return false
            }
            return true
        }
        self.addGestureRecognizer(panRecognizer)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.addGestureRecognizer(tapRecognizer)
        
        self.buttonsView.mute = { [weak self] in
            self?.toggleMute?()
            self?.cancelScheduledUIHiding()
        }
        
        self.buttonsView.speaker = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.beginAudioOuputSelection?(strongSelf.hasVideoNodes)
            strongSelf.cancelScheduledUIHiding()
        }
                
        self.buttonsView.acceptOrEnd = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active, .connecting, .reconnecting:
                strongSelf.endCall?()
                strongSelf.cancelScheduledUIHiding()
            case .requesting:
                strongSelf.endCall?()
            case .ringing:
                strongSelf.acceptCall?()
            default:
                break
            }
        }
        
        self.buttonsView.decline = { [weak self] in
            self?.endCall?()
        }
        
        self.buttonsView.toggleVideo = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active:
                var isScreencastActive = false
                switch callState.videoState {
                case .active(true), .paused(true):
                    isScreencastActive = true
                default:
                    break
                }

                if isScreencastActive {
                    (strongSelf.call as! PresentationCallImpl).disableScreencast()
                } else if strongSelf.outgoingVideoView == nil && strongSelf.outgoingVideoPreviewContainer == nil {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), onlyCheck: true, presentationData: strongSelf.presentationData, present: { [weak self] c, a in
                        if let strongSelf = self {
                            strongSelf.present?(c)
                        }
                    }, openSettings: { [weak self] in
                        self?.sharedContext.applicationBindings.openSettings()
                    }, _: { [weak self] ready in
                        guard let strongSelf = self, ready else {
                            return
                        }
                        let delayUntilInitialized = strongSelf.isRequestingVideo
                        strongSelf.call.makeOutgoingVideoView(completion: { [weak self] (presentationCallVideoView) in
                            guard let strongSelf = self else {
                                return
                            }

                            if let presentationCallVideoViewActual = presentationCallVideoView {
                                presentationCallVideoViewActual.view.backgroundColor = .black
                                presentationCallVideoViewActual.view.clipsToBounds = true

                                let applyNode: () -> Void = {
                                    guard let strongSelf = self,
                                          let outgoingVideoPreviewViewActual = strongSelf.candidateOutgoingVideoPreviewView else {
                                        return
                                    }
                                    let outgoingVideoPreviewContainer = UIView()
                                    strongSelf.outgoingVideoPreviewContainer = outgoingVideoPreviewContainer
                                    strongSelf.contentContainerView.addSubview(outgoingVideoPreviewContainer)

                                    strongSelf.candidateOutgoingVideoPreviewView = nil
                                    strongSelf.animateOutgoingVideoPreviewContainerOnce = true
                                    strongSelf.outgoingVideoPreviewView = outgoingVideoPreviewViewActual
                                    outgoingVideoPreviewContainer.addSubview(outgoingVideoPreviewViewActual)

                                    let cancelOutgoingVideoPreviewButtonNode = HighlightableButtonNode()
                                    strongSelf.cancelOutgoingVideoPreviewButtonNode = cancelOutgoingVideoPreviewButtonNode
                                    cancelOutgoingVideoPreviewButtonNode.setTitle(presentationData.strings.Common_Cancel, with: Font.regular(17.0), with: .white, for: [])
                                    cancelOutgoingVideoPreviewButtonNode.accessibilityLabel = presentationData.strings.Call_VoiceOver_Minimize
                                    cancelOutgoingVideoPreviewButtonNode.accessibilityTraits = [.button]
                                    cancelOutgoingVideoPreviewButtonNode.hitTestSlop = UIEdgeInsets(top: -8.0, left: -20.0, bottom: -8.0, right: -8.0)
                                    cancelOutgoingVideoPreviewButtonNode.highligthedChanged = { [weak self] highlighted in
                                        if let strongSelf = self, let buttonNode = strongSelf.cancelOutgoingVideoPreviewButtonNode {
                                            if highlighted {
                                                buttonNode.layer.removeAnimation(forKey: "opacity")
                                                buttonNode.alpha = 0.4
                                            } else {
                                                buttonNode.alpha = 1.0
                                                buttonNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                                            }
                                        }
                                    }
                                    cancelOutgoingVideoPreviewButtonNode.addTarget(self,
                                                                                   action: #selector(strongSelf.cancelOutgoingVideoPreviewPressed),
                                                                                   forControlEvents: .touchUpInside)
                                    outgoingVideoPreviewContainer.addSubnode(cancelOutgoingVideoPreviewButtonNode)

                                    let theme = SolidRoundedButtonTheme(backgroundColor: UIColor(rgb: 0xffffff),
                                                                        foregroundColor: UIColor(rgb: 0x4f5352))
                                    let outgoingVideoPreviewDoneButton = SolidRoundedButtonNode(theme: theme,
                                                                                                font: .bold,
                                                                                                height: 50.0,
                                                                                                cornerRadius: 10.0,
                                                                                                gloss: false)
                                    strongSelf.outgoingVideoPreviewDoneButton = outgoingVideoPreviewDoneButton
                                    outgoingVideoPreviewDoneButton.title = presentationData.strings.VoiceChat_VideoPreviewContinue
                                    outgoingVideoPreviewContainer.addSubnode(outgoingVideoPreviewDoneButton)
                                    outgoingVideoPreviewDoneButton.pressed = { [weak self] in
                                        guard let strongSelf = self, let outgoingVideoPreviewView = strongSelf.outgoingVideoPreviewView else {
                                            return
                                        }
                                        strongSelf.outgoingVideoPreviewContainer?.removeFromSuperview()
                                        strongSelf.outgoingVideoPreviewContainer = nil
                                        strongSelf.outgoingVideoView = outgoingVideoPreviewView
                                        if let expandedVideoNode = strongSelf.expandedVideoNode {
                                            strongSelf.minimizedVideoNode = outgoingVideoPreviewView
                                            strongSelf.videoContainerNode.contentView.insertSubview(outgoingVideoPreviewView, aboveSubview: expandedVideoNode)
                                        } else {
                                            strongSelf.expandedVideoNode = outgoingVideoPreviewView
                                            strongSelf.videoContainerNode.contentView.addSubview(outgoingVideoPreviewView)
                                        }
                                        strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))

                                        strongSelf.updateDimVisibility()
                                        strongSelf.maybeScheduleUIHidingForActiveVideoCall()

                                        if strongSelf.hasVideoNodes {
                                            strongSelf.setUIState(.video)
                                        }

                                        strongSelf.displayedCameraConfirmation = true
                                        switch callState.videoState {
                                        case .inactive:
                                            strongSelf.isRequestingVideo = true
                                            strongSelf.updateButtonsMode()
                                        default:
                                            break
                                        }
                                        strongSelf.call.requestVideo()
                                    }

                                    strongSelf.outgoingVideoPreviewWheelSelectedTabIndex = 1
                                    let wheelNode = WheelControlNodeNew(items: [WheelControlNodeNew.Item(title: UIDevice.current.model == "iPad" ? strongSelf.presentationData.strings.VoiceChat_VideoPreviewTabletScreen : strongSelf.presentationData.strings.VoiceChat_VideoPreviewPhoneScreen), WheelControlNodeNew.Item(title: strongSelf.presentationData.strings.VoiceChat_VideoPreviewFrontCamera), WheelControlNodeNew.Item(title: strongSelf.presentationData.strings.VoiceChat_VideoPreviewBackCamera)], selectedIndex: strongSelf.outgoingVideoPreviewWheelSelectedTabIndex)
                                    strongSelf.outgoingVideoPreviewWheelNode = wheelNode
                                    wheelNode.selectedIndexChanged = { [weak self] index in
                                        if let strongSelf = self {
                                            if (index == 1 && strongSelf.outgoingVideoPreviewWheelSelectedTabIndex == 2) || (index == 2 && strongSelf.outgoingVideoPreviewWheelSelectedTabIndex == 1) {
                                                Queue.mainQueue().after(0.1) {
                                                    strongSelf.call.switchVideoCamera()
                                                }
                                                strongSelf.outgoingVideoPreviewView?.flip(withBackground: false)
                                            }
                                            if index == 0 && [1, 2].contains(strongSelf.outgoingVideoPreviewWheelSelectedTabIndex) {
                                                strongSelf.outgoingVideoPreviewBroadcastPickerView?.isHidden = false
                                                strongSelf.outgoingVideoPreviewView?.updateIsBlurred(isBlurred: true, light: false, animated: true)
                                                let transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut)
                                                if let placeholderTextNode = strongSelf.outgoingVideoPreviewPlaceholderTextNode {
                                                    transition.updateAlpha(node: placeholderTextNode, alpha: 1.0)
                                                }
                                                if let placeholderIconNode = strongSelf.outgoingVideoPreviewPlaceholderIconNode {
                                                    transition.updateAlpha(node: placeholderIconNode, alpha: 1.0)
                                                }
                                            } else if [1, 2].contains(index) && strongSelf.outgoingVideoPreviewWheelSelectedTabIndex == 0 {
                                                strongSelf.outgoingVideoPreviewBroadcastPickerView?.isHidden = true
                                                strongSelf.outgoingVideoPreviewView?.updateIsBlurred(isBlurred: false, light: false, animated: true)
                                                let transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut)
                                                if let placeholderTextNode = strongSelf.outgoingVideoPreviewPlaceholderTextNode {
                                                    transition.updateAlpha(node: placeholderTextNode, alpha: 0.0)
                                                }
                                                if let placeholderIconNode = strongSelf.outgoingVideoPreviewPlaceholderIconNode {
                                                    transition.updateAlpha(node: placeholderIconNode, alpha: 0.0)
                                                }
                                            }
                                            strongSelf.outgoingVideoPreviewWheelSelectedTabIndex = index
                                        }
                                    }
                                    outgoingVideoPreviewContainer.addSubnode(wheelNode)

                                    if #available(iOS 12.0, *) {
                                        let broadcastPickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 52.0))
                                        broadcastPickerView.alpha = 0.02
                                        broadcastPickerView.isHidden = true
                                        broadcastPickerView.preferredExtension = "\(strongSelf.sharedContext.applicationBindings.appBundleId).BroadcastUpload"
                                        broadcastPickerView.showsMicrophoneButton = false
                                        strongSelf.outgoingVideoPreviewBroadcastPickerView = broadcastPickerView
                                        outgoingVideoPreviewContainer.addSubview(broadcastPickerView)
                                    }

                                    let outgoingVideoPreviewPlaceholderTextNode = ImmediateTextNode()
                                    strongSelf.outgoingVideoPreviewPlaceholderTextNode = outgoingVideoPreviewPlaceholderTextNode
                                    outgoingVideoPreviewPlaceholderTextNode.alpha = 0.0
                                    outgoingVideoPreviewPlaceholderTextNode.maximumNumberOfLines = 3
                                    outgoingVideoPreviewPlaceholderTextNode.textAlignment = .center
                                    outgoingVideoPreviewContainer.addSubnode(outgoingVideoPreviewPlaceholderTextNode)

                                    let outgoingVideoPreviewPlaceholderIconNode = ASImageNode()
                                    strongSelf.outgoingVideoPreviewPlaceholderIconNode = outgoingVideoPreviewPlaceholderIconNode
                                    outgoingVideoPreviewPlaceholderIconNode.alpha = 0.0
                                    outgoingVideoPreviewPlaceholderIconNode.contentMode = .scaleAspectFit
                                    outgoingVideoPreviewPlaceholderIconNode.displaysAsynchronously = false
                                    outgoingVideoPreviewContainer.addSubnode(outgoingVideoPreviewPlaceholderIconNode)

                                    strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))

                                    strongSelf.setUIState(.videoPreview)
                                }

                                let outgoingVideoPreviewView = CallVideoView(
                                    videoView: presentationCallVideoViewActual,
                                    disabledText: nil,
                                    assumeReadyAfterTimeout: true,
                                    isReadyUpdated: {
                                        if delayUntilInitialized {
                                            Queue.mainQueue().after(0.4, {
                                                applyNode()
                                            })
                                        }
                                    }, orientationUpdated: {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                                        }
                                    }, isFlippedUpdated: { videoNode in
                                        guard let _ = self else {
                                            return
                                        }
                                    })

                                strongSelf.candidateOutgoingVideoPreviewView = outgoingVideoPreviewView
                                strongSelf.setupAudioOutputs()

                                if !delayUntilInitialized {
                                    applyNode()
                                }
                            }
                        })
                    })
                } else {
                    strongSelf.call.disableVideo()
                    strongSelf.cancelScheduledUIHiding()
                }
            default:
                break
            }
        }
        
        self.buttonsView.rotateCamera = { [weak self] in
            guard let strongSelf = self, !strongSelf.areUserActionsDisabledNow() else {
                return
            }
            strongSelf.disableActionsUntilTimestamp = CACurrentMediaTime() + 1.0
            if let outgoingVideoNode = strongSelf.outgoingVideoView {
                outgoingVideoNode.flip(withBackground: outgoingVideoNode !== strongSelf.minimizedVideoNode)
            }
            strongSelf.call.switchVideoCamera()
            if let _ = strongSelf.outgoingVideoView {
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                }
            }
            strongSelf.cancelScheduledUIHiding()
        }
        
        self.keyButtonNode.addTarget(self, action: #selector(self.keyPressed), forControlEvents: .touchUpInside)
        
        self.backButtonNode.addTarget(self, action: #selector(self.backPressed), forControlEvents: .touchUpInside)
        
        if shouldStayHiddenUntilConnection {
            self.contentContainerView.alpha = 0.0
            Queue.mainQueue().after(3.0, { [weak self] in
                self?.contentContainerView.alpha = 1.0
                self?.animateIn()
            })
        } else if call.isVideo && call.isOutgoing {
            self.contentContainerView.alpha = 0.0
            Queue.mainQueue().after(1.0, { [weak self] in
                self?.contentContainerView.alpha = 1.0
                self?.animateIn()
            })
        }
        
        self.orientationDidChangeObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            let deviceOrientation = UIDevice.current.orientation
            if strongSelf.deviceOrientation != deviceOrientation {
                strongSelf.deviceOrientation = deviceOrientation
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
            }
        })
        
        self.videoContainerNode.activate = { [weak self] sourceNode in
            guard let strongSelf = self else {
                return
            }
            let pinchController = PinchViewController(sourceNode: sourceNode, getContentAreaInScreenSpace: {
                return UIScreen.main.bounds
            })
            strongSelf.sharedContext.mainWindow?.presentInGlobalOverlay(pinchController)
            strongSelf.isVideoPinched = true
            
            strongSelf.videoContainerNode.contentView.clipsToBounds = true
            strongSelf.videoContainerNode.backgroundColor = .black
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.videoContainerNode.contentView.layer.cornerRadius = layout.deviceMetrics.screenCornerRadius
                
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
        
        self.videoContainerNode.animatedOut = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isVideoPinched = false
            
            strongSelf.videoContainerNode.backgroundColor = .clear
            strongSelf.videoContainerNode.contentView.layer.cornerRadius = 0.0
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let orientationDidChangeObserver = self.orientationDidChangeObserver {
            NotificationCenter.default.removeObserver(orientationDidChangeObserver)
        }
    }

    // MARK: - Overrides

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.debugNode != nil {
            return super.hitTest(point, with: event)
        }
        if self.containerTransformationView.frame.contains(point) {
            return self.containerTransformationView.hitTest(self.convert(point, to: self.containerTransformationView), with: event)
        }
        return nil
    }

    // MARK: - Public
    
    func displayCameraTooltip() {
        guard self.pictureInPictureTransitionFraction.isZero, let location = self.buttonsView.videoButtonFrame().flatMap({ frame -> CGRect in
            return self.buttonsView.convert(frame, to: self)
        }) else {
            return
        }
                
        self.present?(TooltipScreen(account: self.account, text: self.presentationData.strings.Call_CameraOrScreenTooltip, style: .light, icon: nil, location: .point(location.offsetBy(dx: 0.0, dy: -14.0), .bottom), displayDuration: .custom(5.0), shouldDismissOnTouch: { _ in
            return .dismiss(consume: false)
        }))
    }
    
    func updatePeer(accountPeer: Peer, peer: Peer, hasOther: Bool) {
        if !arePeersEqual(self.peer, peer) {
            self.peer = peer
            if PeerReference(peer) != nil && !peer.profileImageRepresentations.isEmpty {
                self.dimNode.isHidden = false
            } else {
                self.dimNode.isHidden = true
            }

            self.avatarNode.setPeer(context: self.accountContext,
                                    account: self.account,
                                    theme: presentationData.theme,
                                    peer: EnginePeer(peer),
                                    overrideImage: nil,
                                    clipStyle: .none,
                                    synchronousLoad: false,
                                    displayDimensions: self.avatarNode.bounds.size)

            setUIState(.ringing)
            
            self.toastNode.title = EnginePeer(peer).compactDisplayTitle
            self.statusNode.title = EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            if hasOther {
                self.statusNode.subtitle = self.presentationData.strings.Call_AnsweringWithAccount(EnginePeer(accountPeer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                
                if let callState = self.callState {
                    self.updateCallState(callState)
                }
            }
            
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
    }
    
    func updateAudioOutputs(availableOutputs: [AudioSessionOutput], currentOutput: AudioSessionOutput?) {
        if self.audioOutputState?.0 != availableOutputs || self.audioOutputState?.1 != currentOutput {
            self.audioOutputState = (availableOutputs, currentOutput)
            self.updateButtonsMode()
            
            self.setupAudioOutputs()
        }
    }

    func updateAudioLevel(_ audionLevel: CGFloat) {
        if !audioLevelView.isHidden {
            audioLevelView.updateLevel(audionLevel)
        }
    }
    
    func updateCallState(_ callState: PresentationCallState) {
        self.callState = callState
        
        let statusValue: CallControllerStatusValue
        var statusReception: Int32?
        
        switch callState.remoteVideoState {
        case .active, .paused:
            if !self.incomingVideoViewRequested {
                self.incomingVideoViewRequested = true
                let delayUntilInitialized = true
                self.call.makeIncomingVideoView(completion: { [weak self] incomingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let incomingVideoView = incomingVideoView {
                        incomingVideoView.view.backgroundColor = .black
                        incomingVideoView.view.clipsToBounds = true
                        
                        let applyNode: () -> Void = {
                            guard let strongSelf = self, let incomingVideoNode = strongSelf.candidateIncomingVideoNodeValue else {
                                return
                            }
                            strongSelf.candidateIncomingVideoNodeValue = nil
                            strongSelf.animateIncomingVideoPreviewContainerOnce = true
                            strongSelf.incomingVideoNodeValue = incomingVideoNode
                            if let expandedVideoNode = strongSelf.expandedVideoNode {
                                strongSelf.minimizedVideoNode = expandedVideoNode
                                strongSelf.videoContainerNode.contentView.insertSubview(incomingVideoNode, belowSubview: expandedVideoNode)
                            } else {
                                strongSelf.videoContainerNode.contentView.addSubview(incomingVideoNode)
                            }
                            strongSelf.expandedVideoNode = incomingVideoNode
                            strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
                            
                            strongSelf.updateDimVisibility()
                            strongSelf.maybeScheduleUIHidingForActiveVideoCall()

                            if strongSelf.hasVideoNodes {
                                strongSelf.setUIState(.video)
                            }
                        }
                        
                        let incomingVideoNode = CallVideoView(videoView: incomingVideoView, disabledText: strongSelf.presentationData.strings.Call_RemoteVideoPaused(strongSelf.peer.flatMap(EnginePeer.init)?.compactDisplayTitle ?? "").string, assumeReadyAfterTimeout: false, isReadyUpdated: {
                            if delayUntilInitialized {
                                Queue.mainQueue().after(0.1, {
                                    applyNode()
                                })
                            }
                        }, orientationUpdated: {
                            guard let strongSelf = self else {
                                return
                            }
                            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }, isFlippedUpdated: { _ in
                        })
                        strongSelf.candidateIncomingVideoNodeValue = incomingVideoNode
                        strongSelf.setupAudioOutputs()
                        
                        if !delayUntilInitialized {
                            applyNode()
                        }
                    }
                })
            }
        case .inactive:
            self.candidateIncomingVideoNodeValue = nil
            if let incomingVideoNodeValue = self.incomingVideoNodeValue {
                if self.minimizedVideoNode == incomingVideoNodeValue {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = incomingVideoNodeValue
                }
                if self.expandedVideoNode == incomingVideoNodeValue {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = incomingVideoNodeValue
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                    setUIState(hasVideoNodes ? .video : .active)
                }
                self.incomingVideoNodeValue = nil
                self.incomingVideoViewRequested = false
            }
        }
        
        switch callState.videoState {
        case .active(false), .paused(false):
            if !self.outgoingVideoViewRequested {
                self.outgoingVideoViewRequested = true
                self.isRequestingVideo = false
                self.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
            }

        default:
            if let outgoingVideoView = self.outgoingVideoView {
                if self.minimizedVideoNode == outgoingVideoView {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = outgoingVideoView
                }
                if self.expandedVideoNode == self.outgoingVideoView {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = outgoingVideoView
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                    if hasVideoNodes {
                        setUIState(.video)
                    } else {
                        setUIState(.active)
                    }
                }
                self.outgoingVideoView = nil
                self.outgoingVideoViewRequested = false
            }
        }
        
        if let incomingVideoNode = self.incomingVideoNodeValue {
            switch callState.state {
            case .terminating, .terminated:
                break
            default:
                let isActive: Bool
                switch callState.remoteVideoState {
                case .inactive, .paused:
                    isActive = false
                case .active:
                    isActive = true
                }
                incomingVideoNode.updateIsBlurred(isBlurred: !isActive)
            }
        }
                
        switch callState.state {
            case .waiting, .connecting:
                statusValue = .text(string: self.presentationData.strings.Call_StatusConnecting, displayLogo: false)
            case let .requesting(ringing):
                if ringing {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRinging, displayLogo: false)
                } else {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRequesting, displayLogo: false)
                }
            case .terminating:
                statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false)
            case let .terminated(_, reason, _):
                if let reason = reason {
                    switch reason {
                        case let .ended(type):
                            switch type {
                                case .busy:
                                    statusValue = .text(string: self.presentationData.strings.Call_StatusBusy, displayLogo: false)
                                case .hungUp, .missed:
                                    statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false)
                            }
                        case let .error(error):
                            let text = self.presentationData.strings.Call_StatusFailed
                            switch error {
                            case let .notSupportedByPeer(isVideo):
                                if !self.displayedVersionOutdatedAlert, let peer = self.peer {
                                    self.displayedVersionOutdatedAlert = true
                                    
                                    let text: String
                                    if isVideo {
                                        text = self.presentationData.strings.Call_ParticipantVideoVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    } else {
                                        text = self.presentationData.strings.Call_ParticipantVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    }
                                    
                                    self.present?(textAlertController(sharedContext: self.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {
                                    })]))
                                }
                            default:
                                break
                            }
                            statusValue = .text(string: text, displayLogo: false)
                    }
                } else {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false)
                }
            case .ringing:
                var text: String
                if self.call.isVideo {
                    text = self.presentationData.strings.Call_IncomingVideoCall
                } else {
                    text = self.presentationData.strings.Call_IncomingVoiceCall
                }
                if !self.statusNode.subtitle.isEmpty {
                    text += "\n\(self.statusNode.subtitle)"
                }
                statusValue = .text(string: text, displayLogo: false)
        case .active(let timestamp, let reception, let keyVisualHash),
                .reconnecting(let timestamp, let reception, let keyVisualHash):

                let strings = self.presentationData.strings
                var isReconnecting = false
                if case .reconnecting = callState.state {
                    isReconnecting = true
                }
                if self.keyTextData?.0 != keyVisualHash {
                    let text = stringForEmojiHashOfData(keyVisualHash, 4)!
                    self.keyTextData = (keyVisualHash, text)

                    self.keyButtonNode.key = text
                    
                    let keyTextSize = self.keyButtonNode.measure(CGSize(width: 200.0, height: 200.0))
                    self.keyButtonNode.frame = CGRect(origin: self.keyButtonNode.frame.origin, size: keyTextSize)
                    
                    self.keyButtonNode.animateIn()
                    
                    if let (layout, navigationBarHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                    }
                }
                
                statusValue = .timer({ value, measure in
                    if isReconnecting || (self.outgoingVideoViewRequested && value == "00:00" && !measure) {
                        return strings.Call_StatusConnecting
                    } else {
                        return value
                    }
                }, timestamp)
                if case .active = callState.state {
                    statusReception = reception
                    if let statusReceptionActual = statusReception {
                        setUIState(statusReceptionActual > 1 ? .active : .weakSignal)
                    } else {
                        setUIState(.active)
                    }
                } else {
                    setUIState(.active)
                }
        }
        if self.shouldStayHiddenUntilConnection {
            switch callState.state {
                case .connecting, .active:
                    self.contentContainerView.alpha = 1.0
                default:
                    break
            }
        }
        self.statusNode.status = statusValue
        self.statusNode.reception = statusReception
        
        if let callState = self.callState {
            switch callState.state {
            case .active, .connecting, .reconnecting:
                break
            default:
                self.isUIHidden = false
            }
        }
        
        self.updateToastContent()
        self.updateButtonsMode()
        self.updateDimVisibility()
        
        if self.incomingVideoViewRequested || self.outgoingVideoViewRequested {
            if self.incomingVideoViewRequested && self.outgoingVideoViewRequested {
                self.displayedCameraTooltip = true
            }
            self.displayedCameraConfirmation = true
        }
        if self.incomingVideoViewRequested && !self.outgoingVideoViewRequested && !self.displayedCameraTooltip && (self.toastContent?.isEmpty ?? true) {
            self.displayedCameraTooltip = true
            Queue.mainQueue().after(2.0) {
                self.displayCameraTooltip()
            }
        }
        
        if case let .terminated(id, _, reportRating) = callState.state, let callId = id {
            let presentRating = reportRating || self.forceReportRating
            if presentRating {
                self.presentCallRating?(callId, self.call.isVideo)
            }
            self.callEnded?(presentRating)
        }
        
        let hasIncomingVideoNode = self.incomingVideoNodeValue != nil && self.expandedVideoNode === self.incomingVideoNodeValue
        self.videoContainerNode.isPinchGestureEnabled = hasIncomingVideoNode
    }
    
    func animateIn() {
        if !self.contentContainerView.alpha.isZero {
            var bounds = self.bounds
            bounds.origin = CGPoint()
            self.bounds = bounds
            self.layer.removeAnimation(forKey: "bounds")
            self.statusBar.layer.removeAnimation(forKey: "opacity")
            self.contentContainerView.layer.removeAnimation(forKey: "opacity")
            self.contentContainerView.layer.removeAnimation(forKey: "scale")
            self.statusBar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            if !self.shouldStayHiddenUntilConnection {
                self.contentContainerView.layer.animateScale(from: 1.04, to: 1.0, duration: 0.3)
                self.contentContainerView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.statusBar.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        if !self.shouldStayHiddenUntilConnection || self.contentContainerView.alpha > 0.0 {
            self.contentContainerView.layer.allowsGroupOpacity = true
            self.contentContainerView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak self] _ in
                self?.contentContainerView.layer.allowsGroupOpacity = false
            })
            self.contentContainerView.layer.animateScale(from: 1.0, to: 1.04, duration: 0.3, removeOnCompletion: false, completion: { _ in
                completion()
            })
        } else {
            completion()
        }
    }
    
    func expandFromPipIfPossible() {
        if self.pictureInPictureTransitionFraction.isEqual(to: 1.0), let (layout, navigationHeight) = self.validLayout {
            self.pictureInPictureTransitionFraction = 0.0
            
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        
        var mappedDeviceOrientation = self.deviceOrientation
        var isCompactLayout = true
        if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
            mappedDeviceOrientation = .portrait
            isCompactLayout = false
        }
        
        if !self.hasVideoNodes {
            self.isUIHidden = false
        }
        
        var isUIHidden = self.isUIHidden
        switch self.callState?.state {
        case .terminated, .terminating:
            isUIHidden = false
        default:
            break
        }
        
        var uiDisplayTransition: CGFloat = isUIHidden ? 0.0 : 1.0
        let pipTransitionAlpha: CGFloat = 1.0 - self.pictureInPictureTransitionFraction
        uiDisplayTransition *= pipTransitionAlpha
        
        let pinchTransitionAlpha: CGFloat = self.isVideoPinched ? 0.0 : 1.0
        
        let previousVideoButtonFrame = self.buttonsView.videoButtonFrame().flatMap { frame -> CGRect in
            return self.buttonsView.convert(frame, to: self)
        }
        
        let buttonsHeight: CGFloat
        if let buttonsMode = self.buttonsMode {
            buttonsHeight = self.buttonsView.updateLayout(strings: self.presentationData.strings, mode: buttonsMode, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom, transition: transition)
        } else {
            buttonsHeight = 0.0
        }
        let defaultButtonsOriginY = layout.size.height - buttonsHeight
        let buttonsCollapsedOriginY = self.pictureInPictureTransitionFraction > 0.0 ? layout.size.height + 30.0 : layout.size.height + 10.0
        let buttonsOriginY = interpolate(from: buttonsCollapsedOriginY, to: defaultButtonsOriginY, value: uiDisplayTransition)
        
        let toastHeight = self.toastNode.updateLayout(strings: self.presentationData.strings, content: self.toastContent, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom + buttonsHeight, transition: transition)
        
        let toastSpacing: CGFloat = 22.0
        let toastCollapsedOriginY = self.pictureInPictureTransitionFraction > 0.0 ? layout.size.height : layout.size.height - max(layout.intrinsicInsets.bottom, 20.0) - toastHeight
        let toastOriginY = interpolate(from: toastCollapsedOriginY, to: defaultButtonsOriginY - toastSpacing - toastHeight, value: uiDisplayTransition)
        
        var overlayAlpha: CGFloat = min(pinchTransitionAlpha, uiDisplayTransition)
        var toastAlpha: CGFloat = min(pinchTransitionAlpha, pipTransitionAlpha)
        
        switch self.callState?.state {
        case .terminated, .terminating:
            overlayAlpha *= 0.5
            toastAlpha *= 0.5
        default:
            break
        }
        
        let containerFullScreenFrame = CGRect(origin: CGPoint(), size: layout.size)
        let containerPictureInPictureFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationBarHeight)
        
        let containerFrame = interpolateFrame(from: containerFullScreenFrame, to: containerPictureInPictureFrame, t: self.pictureInPictureTransitionFraction)
        
        transition.updateFrame(view: self.containerTransformationView, frame: containerFrame)
        transition.updateSublayerTransformScale(view: self.containerTransformationView, scale: min(1.0, containerFrame.width / layout.size.width * 1.01))
        transition.updateCornerRadius(layer: self.containerTransformationView.layer, cornerRadius: self.pictureInPictureTransitionFraction * 10.0)
        
        transition.updateFrame(view: self.contentContainerView, frame: CGRect(origin: CGPoint(x: (containerFrame.width - layout.size.width) / 2.0, y: floor(containerFrame.height - layout.size.height) / 2.0), size: layout.size))
        transition.updateFrame(view: self.videoContainerNode, frame: containerFullScreenFrame)
        self.videoContainerNode.update(size: containerFullScreenFrame.size, transition: transition)
        
        transition.updateAlpha(node: self.dimNode, alpha: pinchTransitionAlpha)
        transition.updateFrame(node: self.dimNode, frame: containerFullScreenFrame)
        
        if let keyPreviewNode = self.keyPreviewNode {
            transition.updateFrame(view: keyPreviewNode, frame: containerFullScreenFrame)
            keyPreviewNode.updateLayout(size: layout.size, transition: .immediate)
        }

        transition.updateFrame(node: gradientBackgroundNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        gradientBackgroundNode.updateLayout(size: layout.size, transition: transition, extendAnimation: false, backwards: false, completion: {})
        
        let navigationOffset: CGFloat = max(20.0, layout.safeInsets.top)
        let topOriginY = interpolate(from: -20.0, to: navigationOffset, value: uiDisplayTransition)
        
        let backSize = self.backButtonNode.measure(CGSize(width: 320.0, height: 100.0))
        if let image = self.backButtonArrowNode.image {
            transition.updateFrame(node: self.backButtonArrowNode, frame: CGRect(origin: CGPoint(x: 10.0, y: topOriginY + 25.0), size: image.size))
        }
        transition.updateFrame(node: self.backButtonNode, frame: CGRect(origin: CGPoint(x: 29.0, y: topOriginY + 25.0), size: backSize))
        
        transition.updateAlpha(node: self.backButtonArrowNode, alpha: overlayAlpha)
        transition.updateAlpha(node: self.backButtonNode, alpha: overlayAlpha)
        transition.updateAlpha(node: self.toastNode, alpha: toastAlpha)
        
        var topOffset: CGFloat = layout.safeInsets.top + 174

        let previousAvatarFrame = avatarNode.view.convert(avatarNode.view.bounds, to: self)
        let avatarFrame = CGRect(origin: CGPoint(x: (layout.size.width - avatarNode.bounds.width) / 2.0, y: topOffset),
                                 size: self.avatarNode.bounds.size)
        transition.updateFrame(node: self.avatarNode, frame: avatarFrame)
        transition.updateFrame(view: self.audioLevelView, frame: avatarFrame)

        topOffset += self.avatarNode.bounds.size.height + 40

        let statusHeight = self.statusNode.updateLayout(constrainedWidth: layout.size.width, transition: transition)
        let statusFrame: CGRect
        if hasVideoNodes {
            let statusDefaultOriginY = layout.safeInsets.top + 45
            let statusCollapsedOriginY: CGFloat = -20
            let statusOriginY = interpolate(from: statusCollapsedOriginY, to: statusDefaultOriginY, value: uiDisplayTransition)
            statusFrame = CGRect(origin: CGPoint(x: 0.0, y: statusOriginY),
                                 size: CGSize(width: layout.size.width, height: statusHeight))
        } else {
            statusFrame = CGRect(origin: CGPoint(x: 0.0, y: topOffset),
                                 size: CGSize(width: layout.size.width, height: statusHeight))
        }
        transition.updateFrame(view: self.statusNode, frame: statusFrame)
        transition.updateAlpha(view: self.statusNode, alpha: overlayAlpha)
        
        transition.updateFrame(node: self.toastNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toastOriginY), size: CGSize(width: layout.size.width, height: toastHeight)))
        transition.updateFrame(view: self.buttonsView, frame: CGRect(origin: CGPoint(x: 0.0, y: buttonsOriginY), size: CGSize(width: layout.size.width, height: buttonsHeight)))
        transition.updateAlpha(view: self.buttonsView, alpha: overlayAlpha)
        
        let fullscreenVideoFrame = containerFullScreenFrame
        let previewVideoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationBarHeight)
        
        if let removedMinimizedVideoNodeValue = self.removedMinimizedVideoNodeValue {
            self.removedMinimizedVideoNodeValue = nil
            
            if transition.isAnimated {
                removedMinimizedVideoNodeValue.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                removedMinimizedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedMinimizedVideoNodeValue] _ in
                    removedMinimizedVideoNodeValue?.removeFromSuperview()
                })
            } else {
                removedMinimizedVideoNodeValue.removeFromSuperview()
            }
        }

        if let container = outgoingVideoPreviewContainer {
            transition.updateFrame(view: container, frame: CGRect(origin: CGPoint(), size: layout.size))

            if let cancelOutgoingVideoPreviewButtonNodeActual = cancelOutgoingVideoPreviewButtonNode {
                let transition: ContainedViewLayoutTransition = .immediate
                let size = cancelOutgoingVideoPreviewButtonNodeActual.measure(CGSize(width: 320.0, height: 100.0))
                transition.updateAlpha(node: cancelOutgoingVideoPreviewButtonNodeActual, alpha: 1.0)
                transition.updateFrame(node: cancelOutgoingVideoPreviewButtonNodeActual,
                                       frame: CGRect(origin: CGPoint(x: 29.0, y: topOriginY + 25.0), size: size))
            }

            if let outgoingVideoPreviewDoneButtonActual = outgoingVideoPreviewDoneButton,
               let wheelNode = outgoingVideoPreviewWheelNode {
                let transition: ContainedViewLayoutTransition = .immediate
                let buttonInset: CGFloat = 16.0
                let buttonMaxWidth: CGFloat = 360.0
                let buttonWidth = min(buttonMaxWidth, layout.size.width - buttonInset * 2.0)
                let doneButtonHeight = outgoingVideoPreviewDoneButtonActual.updateLayout(width: buttonWidth, transition: transition)
                transition.updateFrame(node: outgoingVideoPreviewDoneButtonActual, frame: CGRect(x: floorToScreenPixels((layout.size.width - buttonWidth) / 2.0), y: layout.size.height - layout.intrinsicInsets.bottom - doneButtonHeight - buttonInset, width: buttonWidth, height: doneButtonHeight))
                outgoingVideoPreviewBroadcastPickerView?.frame = outgoingVideoPreviewDoneButtonActual.frame

                let wheelFrame = CGRect(origin: CGPoint(x: 16.0, y: layout.size.height - layout.intrinsicInsets.bottom - doneButtonHeight - buttonInset - 36.0 - 20.0), size: CGSize(width: layout.size.width - 32.0, height: 36.0))
                wheelNode.updateLayout(size: wheelFrame.size, transition: transition)
                transition.updateFrame(node: wheelNode, frame: wheelFrame)
            }

            if let placeholderTextNode = outgoingVideoPreviewPlaceholderTextNode,
               let placeholderIconNode = outgoingVideoPreviewPlaceholderIconNode {
                let isTablet: Bool
                if case .regular = layout.metrics.widthClass {
                    isTablet = true
                } else {
                    isTablet = false
                }
                placeholderTextNode.attributedText = NSAttributedString(string: presentationData.strings.VoiceChat_VideoPreviewShareScreenInfo, font: Font.semibold(16.0), textColor: .white)
                placeholderIconNode.image = generateTintedImage(image: UIImage(bundleImageName: isTablet ? "Call/ScreenShareTablet" : "Call/ScreenSharePhone"), color: .white)

                let placeholderTextSize = placeholderTextNode.updateLayout(CGSize(width: layout.size.width - 80.0, height: 100.0))
                transition.updateFrame(node: placeholderTextNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - placeholderTextSize.width) / 2.0), y: floorToScreenPixels(layout.size.height / 2.0) + 10.0), size: placeholderTextSize))
                if let imageSize = placeholderIconNode.image?.size {
                    transition.updateFrame(node: placeholderIconNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - imageSize.width) / 2.0), y: floorToScreenPixels(layout.size.height / 2.0) - imageSize.height - 8.0), size: imageSize))
                }
            }

            if let outgoingVideoPreviewViewActual = outgoingVideoPreviewView {
                var outgoingVideoPreviewVideoTransition: ContainedViewLayoutTransition = transition
                if outgoingVideoPreviewViewActual.frame.isEmpty {
                    outgoingVideoPreviewVideoTransition = .immediate
                }
                outgoingVideoPreviewVideoTransition.updateAlpha(view: outgoingVideoPreviewViewActual, alpha: 1.0)
                outgoingVideoPreviewVideoTransition.updateFrame(view: outgoingVideoPreviewViewActual, frame: fullscreenVideoFrame)
                outgoingVideoPreviewViewActual.updateLayout(size: outgoingVideoPreviewViewActual.frame.size,
                                                            cornerRadius: 0.0,
                                                            isOutgoing: true,
                                                            deviceOrientation: mappedDeviceOrientation,
                                                            isCompactLayout: isCompactLayout,
                                                            transition: outgoingVideoPreviewVideoTransition)
            }
            if animateOutgoingVideoPreviewContainerOnce {
                animateOutgoingVideoPreviewContainerOnce = false
                let videoButtonFrame = self.buttonsView.videoButtonFrame().flatMap { frame -> CGRect in
                    return self.buttonsView.convert(frame, to: self)
                }
                if let previousVideoButtonFrame = previousVideoButtonFrame, let videoButtonFrame = videoButtonFrame {
                    animateRadialMask(view: container, from: previousVideoButtonFrame, to: videoButtonFrame)
                }
            }
        } else if let removedOutgoingVideoPreviewContainerActual = self.removedOutgoingVideoPreviewContainer {
            self.removedOutgoingVideoPreviewContainer = nil

            if transition.isAnimated {
                removedOutgoingVideoPreviewContainerActual.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                removedOutgoingVideoPreviewContainerActual.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedOutgoingVideoPreviewContainerActual] _ in
                    removedOutgoingVideoPreviewContainerActual?.removeFromSuperview()
                })
            } else {
                removedOutgoingVideoPreviewContainerActual.removeFromSuperview()
            }
        }
        
        if let expandedVideoNode = self.expandedVideoNode {
            transition.updateAlpha(view: expandedVideoNode, alpha: 1.0)
            var expandedVideoTransition = transition
            if expandedVideoNode.frame.isEmpty || self.disableAnimationForExpandedVideoOnce {
                expandedVideoTransition = .immediate
                self.disableAnimationForExpandedVideoOnce = false
            }
            
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                expandedVideoTransition.updateFrame(view: expandedVideoNode, frame: fullscreenVideoFrame, completion: { [weak removedExpandedVideoNodeValue] _ in
                    removedExpandedVideoNodeValue?.removeFromSuperview()
                })
            } else {
                expandedVideoTransition.updateFrame(view: expandedVideoNode, frame: fullscreenVideoFrame)
            }
            
            expandedVideoNode.updateLayout(size: expandedVideoNode.frame.size, cornerRadius: 0.0, isOutgoing: expandedVideoNode === self.outgoingVideoView, deviceOrientation: mappedDeviceOrientation, isCompactLayout: isCompactLayout, transition: expandedVideoTransition)
            
            if self.animateIncomingVideoPreviewContainerOnce {
                self.animateIncomingVideoPreviewContainerOnce = false
                if expandedVideoNode === self.incomingVideoNodeValue {
                    let avatarFrame = avatarNode.view.convert(avatarNode.view.bounds, to: self)
                    expandedVideoNode.animateRadialMask(from: previousAvatarFrame, to: avatarFrame)
                }
            }
        } else {
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                if transition.isAnimated {
                    removedExpandedVideoNodeValue.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                    removedExpandedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedExpandedVideoNodeValue] _ in
                        removedExpandedVideoNodeValue?.removeFromSuperview()
                    })
                } else {
                    removedExpandedVideoNodeValue.removeFromSuperview()
                }
            }
        }
        
        
        if let minimizedVideoNode = self.minimizedVideoNode {
            transition.updateAlpha(view: minimizedVideoNode, alpha: min(pipTransitionAlpha, pinchTransitionAlpha))
            var minimizedVideoTransition = transition
            var didAppear = false
            if minimizedVideoNode.frame.isEmpty {
                minimizedVideoTransition = .immediate
                didAppear = true
            }
            if self.minimizedVideoDraggingPosition == nil {
                if let animationForExpandedVideoSnapshotView = self.animationForExpandedVideoSnapshotView {
                    self.contentContainerView.addSubview(animationForExpandedVideoSnapshotView)
                    transition.updateAlpha(layer: animationForExpandedVideoSnapshotView.layer, alpha: 0.0, completion: { [weak animationForExpandedVideoSnapshotView] _ in
                        animationForExpandedVideoSnapshotView?.removeFromSuperview()
                    })
                    transition.updateTransformScale(layer: animationForExpandedVideoSnapshotView.layer, scale: previewVideoFrame.width / fullscreenVideoFrame.width)
                    
                    transition.updatePosition(layer: animationForExpandedVideoSnapshotView.layer, position: CGPoint(x: previewVideoFrame.minX + previewVideoFrame.center.x /  fullscreenVideoFrame.width * previewVideoFrame.width, y: previewVideoFrame.minY + previewVideoFrame.center.y / fullscreenVideoFrame.height * previewVideoFrame.height))
                    self.animationForExpandedVideoSnapshotView = nil
                }
                minimizedVideoTransition.updateFrame(view: minimizedVideoNode, frame: previewVideoFrame)
                minimizedVideoNode.updateLayout(size: previewVideoFrame.size, cornerRadius: interpolate(from: 14.0, to: 24.0, value: self.pictureInPictureTransitionFraction), isOutgoing: minimizedVideoNode === self.outgoingVideoView, deviceOrientation: mappedDeviceOrientation, isCompactLayout: layout.metrics.widthClass == .compact, transition: minimizedVideoTransition)
                if transition.isAnimated && didAppear {
                    minimizedVideoNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                }
            }
            
            self.animationForExpandedVideoSnapshotView = nil
        }
        
        let keyTextSize = self.keyButtonNode.frame.size
        transition.updateFrame(node: self.keyButtonNode, frame: CGRect(origin: CGPoint(x: layout.size.width - keyTextSize.width - 10.0, y: topOriginY + 21.0), size: keyTextSize))
        transition.updateAlpha(node: self.keyButtonNode, alpha: overlayAlpha)
        
        if let debugNode = self.debugNode {
            transition.updateFrame(node: debugNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
        
        let requestedAspect: CGFloat
        if case .compact = layout.metrics.widthClass, case .compact = layout.metrics.heightClass {
            var isIncomingVideoRotated = false
            var rotationCount = 0
            
            switch mappedDeviceOrientation {
            case .portrait:
                break
            case .landscapeLeft:
                rotationCount += 1
            case .landscapeRight:
                rotationCount += 1
            case .portraitUpsideDown:
                 break
            default:
                break
            }
            
            if rotationCount % 2 != 0 {
                isIncomingVideoRotated = true
            }
            
            if !isIncomingVideoRotated {
                requestedAspect = layout.size.width / layout.size.height
            } else {
                requestedAspect = 0.0
            }
        } else {
            requestedAspect = 0.0
        }
        if self.currentRequestedAspect != requestedAspect {
            self.currentRequestedAspect = requestedAspect
            if !self.sharedContext.immediateExperimentalUISettings.disableVideoAspectScaling {
                self.call.setRequestedVideoAspect(Float(requestedAspect))
            }
        }
    }

}

// MARK: - Interface Callbacks

private extension CallControllerView {

    @objc func keyPressed() {
        if self.keyPreviewNode == nil, let keyText = self.keyTextData?.1, let peer = self.peer {
            let keyPreviewNode = CallControllerKeyPreviewView(keyText: keyText, infoText: self.presentationData.strings.Call_EmojiDescription(EnginePeer(peer).compactDisplayTitle).string.replacingOccurrences(of: "%%", with: "%"), dismiss: { [weak self] in
                if let _ = self?.keyPreviewNode {
                    self?.backPressed()
                }
            })

            self.contentContainerView.insertSubview(keyPreviewNode, belowSubview: self.statusNode)
            self.keyPreviewNode = keyPreviewNode

            if let (validLayout, _) = self.validLayout {
                keyPreviewNode.updateLayout(size: validLayout.size, transition: .immediate)

                self.keyButtonNode.isHidden = true
                keyPreviewNode.animateIn(from: self.keyButtonNode.frame, fromNode: self.keyButtonNode)
            }

            self.updateDimVisibility()
        }
    }

    @objc func backPressed() {
        if let keyPreviewNode = self.keyPreviewNode {
            self.keyPreviewNode = nil
            keyPreviewNode.animateOut(to: self.keyButtonNode.frame, toNode: self.keyButtonNode, completion: { [weak self, weak keyPreviewNode] in
                self?.keyButtonNode.isHidden = false
                keyPreviewNode?.removeFromSuperview()
            })
            self.updateDimVisibility()
        } else if self.hasVideoNodes {
            if let (layout, navigationHeight) = self.validLayout {
                self.pictureInPictureTransitionFraction = 1.0
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
            }
        } else {
            self.back?()
        }
    }

    @objc func cancelOutgoingVideoPreviewPressed() {
        guard let outgoingVideoPreviewContainerActual = outgoingVideoPreviewContainer else {
            return
        }
        removedOutgoingVideoPreviewContainer = outgoingVideoPreviewContainerActual
        outgoingVideoPreviewContainer = nil
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
        }
        setUIState(hasVideoNodes ? .video : .active)
    }

    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if !self.pictureInPictureTransitionFraction.isZero {
                self.window?.endEditing(true)

                if let (layout, navigationHeight) = self.validLayout {
                    self.pictureInPictureTransitionFraction = 0.0

                    self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                }
            } else if let _ = self.keyPreviewNode {
                self.backPressed()
            } else {
                if self.hasVideoNodes {
                    let point = recognizer.location(in: recognizer.view)
                    if let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(point) {
                        if !self.areUserActionsDisabledNow() {
                            let copyView = minimizedVideoNode.snapshotView(afterScreenUpdates: false)
                            copyView?.frame = minimizedVideoNode.frame
                            self.expandedVideoNode = minimizedVideoNode
                            self.minimizedVideoNode = expandedVideoNode
                            if let superview = expandedVideoNode.superview {
                                superview.insertSubview(expandedVideoNode, aboveSubview: minimizedVideoNode)
                            }
                            self.disableActionsUntilTimestamp = CACurrentMediaTime() + 0.3
                            if let (layout, navigationBarHeight) = self.validLayout {
                                self.disableAnimationForExpandedVideoOnce = true
                                self.animationForExpandedVideoSnapshotView = copyView
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }
                    } else {
                        var updated = false
                        if let callState = self.callState {
                            switch callState.state {
                            case .active, .connecting, .reconnecting:
                                self.isUIHidden = !self.isUIHidden
                                updated = true
                            default:
                                break
                            }
                        }
                        if updated, let (layout, navigationBarHeight) = self.validLayout {
                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                        }
                    }
                } else {
                    let point = recognizer.location(in: recognizer.view)
                    if self.statusNode.frame.contains(point) {
                        if self.easyDebugAccess {
                            self.presentDebugNode()
                        } else {
                            let timestamp = CACurrentMediaTime()
                            if self.debugTapCounter.0 < timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 = 0
                            }

                            if self.debugTapCounter.0 >= timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 += 1
                            }

                            if self.debugTapCounter.1 >= 10 {
                                self.debugTapCounter.1 = 0

                                self.presentDebugNode()
                            }
                        }
                    }
                }
            }
        }
    }

    private func presentDebugNode() {
        guard self.debugNode == nil else {
            return
        }

        self.forceReportRating = true

        let debugNode = CallDebugNode(signal: self.debugInfo)
        debugNode.dismiss = { [weak self] in
            if let strongSelf = self {
                strongSelf.debugNode?.removeFromSupernode()
                strongSelf.debugNode = nil
            }
        }
        self.addSubnode(debugNode)
        self.debugNode = debugNode

        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }

    @objc private func panGesture(_ recognizer: CallPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                guard let location = recognizer.firstLocation else {
                    return
                }
                if self.pictureInPictureTransitionFraction.isZero, let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(location), expandedVideoNode.frame != minimizedVideoNode.frame {
                    self.minimizedVideoInitialPosition = minimizedVideoNode.center
                } else if self.hasVideoNodes {
                    self.minimizedVideoInitialPosition = nil
                    if !self.pictureInPictureTransitionFraction.isZero {
                        self.pictureInPictureGestureState = .dragging(initialPosition: self.containerTransformationView.center, draggingPosition: self.containerTransformationView.center)
                    } else {
                        self.pictureInPictureGestureState = .collapsing(didSelectCorner: false)
                    }
                } else {
                    self.pictureInPictureGestureState = .none
                }
                self.dismissAllTooltips?()
            case .changed:
                if let minimizedVideoNode = self.minimizedVideoNode, let minimizedVideoInitialPosition = self.minimizedVideoInitialPosition {
                    let translation = recognizer.translation(in: self)
                    let minimizedVideoDraggingPosition = CGPoint(x: minimizedVideoInitialPosition.x + translation.x, y: minimizedVideoInitialPosition.y + translation.y)
                    self.minimizedVideoDraggingPosition = minimizedVideoDraggingPosition
                    minimizedVideoNode.center = minimizedVideoDraggingPosition
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let offset = recognizer.translation(in: self).y
                        var bounds = self.bounds
                        bounds.origin.y = -offset
                        self.bounds = bounds
                    case let .collapsing(didSelectCorner):
                        if let (layout, navigationHeight) = self.validLayout {
                            let offset = recognizer.translation(in: self)
                            if !didSelectCorner {
                                self.pictureInPictureGestureState = .collapsing(didSelectCorner: true)
                                if offset.x < 0.0 {
                                    self.pictureInPictureCorner = .topLeft
                                } else {
                                    self.pictureInPictureCorner = .topRight
                                }
                            }
                            let maxOffset: CGFloat = min(300.0, layout.size.height / 2.0)

                            let offsetTransition = max(0.0, min(1.0, abs(offset.y) / maxOffset))
                            self.pictureInPictureTransitionFraction = offsetTransition
                            switch self.pictureInPictureCorner {
                            case .topRight, .bottomRight:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topRight : .bottomRight
                            case .topLeft, .bottomLeft:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topLeft : .bottomLeft
                            }

                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .immediate)
                        }
                    case .dragging(let initialPosition, var draggingPosition):
                        let translation = recognizer.translation(in: self)
                        draggingPosition.x = initialPosition.x + translation.x
                        draggingPosition.y = initialPosition.y + translation.y
                        self.pictureInPictureGestureState = .dragging(initialPosition: initialPosition, draggingPosition: draggingPosition)
                        self.containerTransformationView.center = draggingPosition
                    }
                }
            case .cancelled, .ended:
                if let minimizedVideoNode = self.minimizedVideoNode, let _ = self.minimizedVideoInitialPosition, let minimizedVideoDraggingPosition = self.minimizedVideoDraggingPosition {
                    self.minimizedVideoInitialPosition = nil
                    self.minimizedVideoDraggingPosition = nil

                    if let (layout, navigationHeight) = self.validLayout {
                        self.outgoingVideoNodeCorner = self.nodeLocationForPosition(layout: layout, position: minimizedVideoDraggingPosition, velocity: recognizer.velocity(in: self))

                        let videoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationHeight)
                        minimizedVideoNode.frame = videoFrame
                        minimizedVideoNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: minimizedVideoDraggingPosition.x - videoFrame.midX, y: minimizedVideoDraggingPosition.y - videoFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                    }
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let velocity = recognizer.velocity(in: self).y
                        if abs(velocity) < 100.0 {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint()
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                        } else {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint(x: 0.0, y: velocity > 0.0 ? -bounds.height: bounds.height)
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.15, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, completion: { [weak self] _ in
                                self?.dismissedInteractively?()
                            })
                        }
                    case .collapsing:
                        self.pictureInPictureGestureState = .none
                        let velocity = recognizer.velocity(in: self).y
                        if abs(velocity) < 100.0 && self.pictureInPictureTransitionFraction < 0.5 {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 0.0

                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        } else {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 1.0

                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        }
                    case let .dragging(initialPosition, _):
                        self.pictureInPictureGestureState = .none
                        if let (layout, navigationHeight) = self.validLayout {
                            let translation = recognizer.translation(in: self)
                            let draggingPosition = CGPoint(x: initialPosition.x + translation.x, y: initialPosition.y + translation.y)
                            self.pictureInPictureCorner = self.nodeLocationForPosition(layout: layout, position: draggingPosition, velocity: recognizer.velocity(in: self))

                            let containerFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationHeight)
                            self.containerTransformationView.frame = containerFrame
                            containerTransformationView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: draggingPosition.x - containerFrame.midX, y: draggingPosition.y - containerFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                        }
                    }
                }
            default:
                break
        }
    }

}

// MARK: - Private

private extension CallControllerView {

    private func setupAudioOutputs() {
        guard self.outgoingVideoView != nil ||
                self.incomingVideoNodeValue != nil ||
                self.candidateIncomingVideoNodeValue != nil ||
                self.outgoingVideoPreviewView != nil ||
                self.candidateOutgoingVideoPreviewView != nil,
              let audioOutputState = self.audioOutputState,
              let currentOutput = audioOutputState.currentOutput else {
            return
        }
        switch currentOutput {
        case .headphones, .speaker:
            break
        case let .port(port) where port.type == .bluetooth || port.type == .wired:
            break
        default:
            self.setCurrentAudioOutput?(.speaker)
        }
    }

    private func setUIState(_ state: UIState) {
        guard uiState != state else {
            return
        }
        let isNewStateAllowed: Bool
        switch uiState {
        case .ringing: isNewStateAllowed = true
        case .active: isNewStateAllowed =  true
        case .weakSignal: isNewStateAllowed = true
        case .video: isNewStateAllowed = !hasVideoNodes || (state == .video && outgoingVideoView == nil)
        case .videoPreview: isNewStateAllowed = outgoingVideoPreviewContainer == nil || state == .video
        case .none: isNewStateAllowed = true
        }
        guard isNewStateAllowed else {
            return
        }
        uiState = state
        switch state {
        case .ringing:
            let colors = [UIColor(rgb: 0xAC65D4), UIColor(rgb: 0x7261DA), UIColor(rgb: 0x5295D6), UIColor(rgb: 0x616AD5)]
            self.gradientBackgroundNode.updateColors(colors: colors)
            avatarNode.isHidden = false
            audioLevelView.isHidden = false
            audioLevelView.startAnimating()
            updateAudioLevel(1.0)
        case .active:
            let colors = [UIColor(rgb: 0x53A6DE), UIColor(rgb: 0x398D6F), UIColor(rgb: 0xBAC05D), UIColor(rgb: 0x3C9C8F)]
            self.gradientBackgroundNode.updateColors(colors: colors)
            avatarNode.isHidden = false
            audioLevelView.isHidden = false
            audioLevelView.startAnimating()
            updateAudioLevel(1.0)
        case .weakSignal:
            let colors = [UIColor(rgb: 0xC94986), UIColor(rgb: 0xFF7E46), UIColor(rgb: 0xB84498), UIColor(rgb: 0xF4992E)]
            self.gradientBackgroundNode.updateColors(colors: colors)
            audioLevelView.startAnimating()
            updateAudioLevel(1.0)
        case .video:
            avatarNode.isHidden = true
            audioLevelView.isHidden = true
            audioLevelView.stopAnimating(duration: 0.5)
        case .videoPreview:
            avatarNode.isHidden = true
            audioLevelView.isHidden = true
            audioLevelView.stopAnimating(duration: 0.5)
        }
    }

    private func updateToastContent() {
        guard let callState = self.callState else {
            return
        }
        if case .terminating = callState.state {

        } else if case .terminated = callState.state {

        } else {
            var toastContent: CallControllerToastContent = []
            if case .active = callState.state {
                if let displayToastsAfterTimestamp = self.displayToastsAfterTimestamp {
                    if CACurrentMediaTime() > displayToastsAfterTimestamp {
                        if case .inactive = callState.remoteVideoState, self.hasVideoNodes {
                            toastContent.insert(.camera)
                        }
                        if case .muted = callState.remoteAudioState {
                            toastContent.insert(.microphone)
                        }
                        if case .low = callState.remoteBatteryLevel {
                            toastContent.insert(.battery)
                        }
                    }
                } else {
                    self.displayToastsAfterTimestamp = CACurrentMediaTime() + 1.5
                }
            }
            if self.isMuted, let (availableOutputs, _) = self.audioOutputState, availableOutputs.count > 2 {
                toastContent.insert(.mute)
            }
            self.toastContent = toastContent
        }
    }

    private func updateDimVisibility(transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)) {
        guard let callState = self.callState else {
            return
        }

        var visible = true
        if case .active = callState.state, self.incomingVideoNodeValue != nil || self.outgoingVideoView != nil {
            visible = false
        }

        let currentVisible = self.dimNode.image == nil
        if visible != currentVisible {
            let color = visible ? UIColor(rgb: 0x000000, alpha: 0.3) : UIColor.clear
            let image: UIImage? = visible ? nil : generateGradientImage(size: CGSize(width: 1.0, height: 640.0), colors: [UIColor.black.withAlphaComponent(0.3), UIColor.clear, UIColor.clear, UIColor.black.withAlphaComponent(0.3)], locations: [0.0, 0.22, 0.7, 1.0])
            if case let .animated(duration, _) = transition {
                UIView.transition(with: self.dimNode.view, duration: duration, options: .transitionCrossDissolve, animations: {
                    self.dimNode.backgroundColor = color
                    self.dimNode.image = image
                }, completion: nil)
            } else {
                self.dimNode.backgroundColor = color
                self.dimNode.image = image
            }
        }
    }

    private func maybeScheduleUIHidingForActiveVideoCall() {
        guard let callState = self.callState, case .active = callState.state, self.incomingVideoNodeValue != nil && self.outgoingVideoView != nil, !self.hiddenUIForActiveVideoCallOnce && self.keyPreviewNode == nil else {
            return
        }

        // TODO: implement
        let timer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
            if let strongSelf = self {
                var updated = false
                if let callState = strongSelf.callState, !strongSelf.isUIHidden {
                    switch callState.state {
                        case .active, .connecting, .reconnecting:
                            strongSelf.isUIHidden = true
                            updated = true
                        default:
                            break
                    }
                }
                if updated, let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
                strongSelf.hideUIForActiveVideoCallTimer = nil
            }
        }, queue: Queue.mainQueue())
        timer.start()
        self.hideUIForActiveVideoCallTimer = timer
        self.hiddenUIForActiveVideoCallOnce = true
    }

    private func cancelScheduledUIHiding() {
        self.hideUIForActiveVideoCallTimer?.invalidate()
        self.hideUIForActiveVideoCallTimer = nil
    }

    private func updateButtonsMode(transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .spring)) {
        guard let callState = self.callState else {
            return
        }

        var mode: CallControllerButtonsSpeakerMode = .none
        var hasAudioRouteMenu: Bool = false
        if let (availableOutputs, maybeCurrentOutput) = self.audioOutputState, let currentOutput = maybeCurrentOutput {
            hasAudioRouteMenu = availableOutputs.count > 2
            switch currentOutput {
                case .builtin:
                    mode = .builtin
                case .speaker:
                    mode = .speaker
                case .headphones:
                    mode = .headphones
                case let .port(port):
                    var type: CallControllerButtonsSpeakerMode.BluetoothType = .generic
                    let portName = port.name.lowercased()
                    if portName.contains("airpods pro") {
                        type = .airpodsPro
                    } else if portName.contains("airpods") {
                        type = .airpods
                    }
                    mode = .bluetooth(type)
            }
            if availableOutputs.count <= 1 {
                mode = .none
            }
        }
        var mappedVideoState = CallControllerButtonsMode.VideoState(isAvailable: false, isCameraActive: self.outgoingVideoView != nil, isScreencastActive: false, canChangeStatus: false, hasVideo: self.outgoingVideoView != nil || self.incomingVideoNodeValue != nil, isInitializingCamera: self.isRequestingVideo)
        switch callState.videoState {
        case .notAvailable:
            break
        case .inactive:
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
        case .active(let isScreencast), .paused(let isScreencast):
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
            if isScreencast {
                mappedVideoState.isScreencastActive = true
                mappedVideoState.hasVideo = true
            }
        }

        switch callState.state {
        case .ringing:
            self.buttonsMode = .incoming(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .waiting, .requesting:
            self.buttonsMode = .outgoingRinging(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .active, .connecting, .reconnecting:
            self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .terminating, .terminated:
            if let buttonsTerminationMode = self.buttonsTerminationMode {
                self.buttonsMode = buttonsTerminationMode
            } else {
                self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            }
        }

        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: transition)
        }
    }

    private func calculatePreviewVideoRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let buttonsHeight: CGFloat = self.buttonsView.bounds.height
        let toastHeight: CGFloat = self.toastNode.bounds.height
        let toastInset = (toastHeight > 0.0 ? toastHeight + 22.0 : 0.0)

        var fullInsets = layout.insets(options: .statusBar)

        var cleanInsets = fullInsets
        cleanInsets.bottom = max(layout.intrinsicInsets.bottom, 10.0) + toastInset
        cleanInsets.left = 10.0
        cleanInsets.right = 10.0

        fullInsets.top += 44.0 + 8.0
        fullInsets.bottom = buttonsHeight + 12.0 + toastInset
        fullInsets.left = 10.0
        fullInsets.right = 10.0

        var insets: UIEdgeInsets = self.isUIHidden ? cleanInsets : fullInsets

        let expandedInset: CGFloat = 16.0

        insets.top = interpolate(from: expandedInset, to: insets.top, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.bottom = interpolate(from: expandedInset, to: insets.bottom, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.left = interpolate(from: expandedInset, to: insets.left, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.right = interpolate(from: expandedInset, to: insets.right, value: 1.0 - self.pictureInPictureTransitionFraction)

        let previewVideoSide = interpolate(from: 300.0, to: 240.0, value: 1.0 - self.pictureInPictureTransitionFraction)
        var previewVideoSize = layout.size.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
        previewVideoSize = CGSize(width: 30.0, height: 45.0).aspectFitted(previewVideoSize)
        if let minimizedVideoNode = self.minimizedVideoNode {
            var aspect = minimizedVideoNode.currentAspect
            var rotationCount = 0
            if minimizedVideoNode === self.outgoingVideoView {
                aspect = 138.0 / 240.0 //3.0 / 4.0
            } else {
                if aspect < 1.0 {
                    aspect = 138.0 / 240.0 //3.0 / 4.0
                } else {
                    aspect = 240.0 / 138.0 // 4.0 / 3.0
                }

                switch minimizedVideoNode.currentOrientation {
                case .rotation90, .rotation270:
                    rotationCount += 1
                default:
                    break
                }

                var mappedDeviceOrientation = self.deviceOrientation
                if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
                    mappedDeviceOrientation = .portrait
                }

                switch mappedDeviceOrientation {
                case .landscapeLeft, .landscapeRight:
                    rotationCount += 1
                default:
                    break
                }

                if rotationCount % 2 != 0 {
                    aspect = 1.0 / aspect
                }
            }

            let unboundVideoSize = CGSize(width: aspect * 10000.0, height: 10000.0)

            previewVideoSize = unboundVideoSize.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
        }
        let previewVideoY: CGFloat
        let previewVideoX: CGFloat

        switch self.outgoingVideoNodeCorner {
        case .topLeft:
            previewVideoX = insets.left
            previewVideoY = insets.top
        case .topRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = insets.top
        case .bottomLeft:
            previewVideoX = insets.left
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        case .bottomRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        }

        return CGRect(origin: CGPoint(x: previewVideoX, y: previewVideoY), size: previewVideoSize)
    }

    private func calculatePictureInPictureContainerRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let pictureInPictureTopInset: CGFloat = layout.insets(options: .statusBar).top + 44.0 + 8.0
        let pictureInPictureSideInset: CGFloat = 8.0
        let pictureInPictureSize = layout.size.fitted(CGSize(width: 240.0, height: 240.0))
        let pictureInPictureBottomInset: CGFloat = layout.insets(options: .input).bottom + 44.0 + 8.0

        let containerPictureInPictureFrame: CGRect
        switch self.pictureInPictureCorner {
        case .topLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .topRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .bottomLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        case .bottomRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        }
        return containerPictureInPictureFrame
    }

    private func nodeLocationForPosition(layout: ContainerViewLayout, position: CGPoint, velocity: CGPoint) -> VideoNodeCorner {
        let layoutInsets = UIEdgeInsets()
        var result = CGPoint()
        if position.x < layout.size.width / 2.0 {
            result.x = 0.0
        } else {
            result.x = 1.0
        }
        if position.y < layoutInsets.top + (layout.size.height - layoutInsets.bottom - layoutInsets.top) / 2.0 {
            result.y = 0.0
        } else {
            result.y = 1.0
        }

        let currentPosition = result

        let angleEpsilon: CGFloat = 30.0
        var shouldHide = false

        if (velocity.x * velocity.x + velocity.y * velocity.y) >= 500.0 * 500.0 {
            let x = velocity.x
            let y = velocity.y

            var angle = atan2(y, x) * 180.0 / CGFloat.pi * -1.0
            if angle < 0.0 {
                angle += 360.0
            }

            if currentPosition.x.isZero && currentPosition.y.isZero {
                if ((angle > 0 && angle < 90 - angleEpsilon) || angle > 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                } else if (angle > 180 + angleEpsilon && angle < 270 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                } else if (angle > 270 + angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                } else {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && currentPosition.y.isZero {
                if (angle > 90 + angleEpsilon && angle < 180 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle > 270 - angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > 180 + angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else {
                    shouldHide = true
                }
            } else if currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > 90 - angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle < angleEpsilon || angle > 270 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > angleEpsilon && angle < 90 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > angleEpsilon && angle < 90 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (angle > 180 - angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else if (angle > 90 + angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            }
        }

        if result.x.isZero {
            if result.y.isZero {
                return .topLeft
            } else {
                return .bottomLeft
            }
        } else {
            if result.y.isZero {
                return .topRight
            } else {
                return .bottomRight
            }
        }
    }

    private func areUserActionsDisabledNow() -> Bool {
        return CACurrentMediaTime() < self.disableActionsUntilTimestamp
    }

    private func animateRadialMask(view: UIView, from fromRect: CGRect, to toRect: CGRect) {
        let maskLayer = CAShapeLayer()
        maskLayer.frame = fromRect

        let path = CGMutablePath()
        path.addEllipse(in: CGRect(origin: CGPoint(), size: fromRect.size))
        maskLayer.path = path

        view.layer.mask = maskLayer

        let topLeft = CGPoint(x: 0.0, y: 0.0)
        let topRight = CGPoint(x: view.bounds.width, y: 0.0)
        let bottomLeft = CGPoint(x: 0.0, y: view.bounds.height)
        let bottomRight = CGPoint(x: view.bounds.width, y: view.bounds.height)

        func distance(_ v1: CGPoint, _ v2: CGPoint) -> CGFloat {
            let dx = v1.x - v2.x
            let dy = v1.y - v2.y
            return sqrt(dx * dx + dy * dy)
        }

        var maxRadius = distance(toRect.center, topLeft)
        maxRadius = max(maxRadius, distance(toRect.center, topRight))
        maxRadius = max(maxRadius, distance(toRect.center, bottomLeft))
        maxRadius = max(maxRadius, distance(toRect.center, bottomRight))
        maxRadius = ceil(maxRadius)

        let targetFrame = CGRect(origin: CGPoint(x: toRect.center.x - maxRadius, y: toRect.center.y - maxRadius), size: CGSize(width: maxRadius * 2.0, height: maxRadius * 2.0))

        let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
        transition.updatePosition(layer: maskLayer, position: targetFrame.center)
        transition.updateTransformScale(layer: maskLayer, scale: maxRadius * 2.0 / fromRect.width, completion: { [weak view] _ in
            view?.layer.mask = nil
        })
    }

}

// MARK: - CallVideoView

private final class CallVideoView: UIView {

    private let videoTransformContainer: UIView
    private let videoView: PresentationCallVideoView

    private var effectView: UIVisualEffectView?
    private let videoPausedNode: ImmediateTextNode

    private var isBlurred: Bool = false
    private var currentCornerRadius: CGFloat = 0.0

    private let isReadyUpdated: () -> Void
    private(set) var isReady: Bool = false
    private var isReadyTimer: SwiftSignalKit.Timer?

    private let readyPromise = ValuePromise(false)
    var ready: Signal<Bool, NoError> {
        return self.readyPromise.get()
    }

    private let isFlippedUpdated: (CallVideoView) -> Void

    private(set) var currentOrientation: PresentationCallVideoView.Orientation
    private(set) var currentAspect: CGFloat = 0.0

    private var previousVideoHeight: CGFloat?

    init(videoView: PresentationCallVideoView, disabledText: String?, assumeReadyAfterTimeout: Bool, isReadyUpdated: @escaping () -> Void, orientationUpdated: @escaping () -> Void, isFlippedUpdated: @escaping (CallVideoView) -> Void) {
        self.isReadyUpdated = isReadyUpdated
        self.isFlippedUpdated = isFlippedUpdated

        self.videoTransformContainer = UIView()
        self.videoView = videoView
        videoView.view.clipsToBounds = true
        videoView.view.backgroundColor = .black

        self.currentOrientation = videoView.getOrientation()
        self.currentAspect = videoView.getAspect()

        self.videoPausedNode = ImmediateTextNode()
        self.videoPausedNode.alpha = 0.0
        self.videoPausedNode.maximumNumberOfLines = 3

        super.init(frame: CGRect.zero)

        self.backgroundColor = .black
        self.clipsToBounds = true

        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }

        self.videoTransformContainer.addSubview(self.videoView.view)
        self.addSubview(self.videoTransformContainer)

        if let disabledText = disabledText {
            self.videoPausedNode.attributedText = NSAttributedString(string: disabledText, font: Font.regular(17.0), textColor: .white)
            self.addSubnode(self.videoPausedNode)
        }

        self.videoView.setOnFirstFrameReceived { [weak self] aspectRatio in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyTimer?.invalidate()
                    strongSelf.isReadyUpdated()
                }
            }
        }

        self.videoView.setOnOrientationUpdated { [weak self] orientation, aspect in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if strongSelf.currentOrientation != orientation || strongSelf.currentAspect != aspect {
                    strongSelf.currentOrientation = orientation
                    strongSelf.currentAspect = aspect
                    orientationUpdated()
                }
            }
        }

        self.videoView.setOnIsMirroredUpdated { [weak self] _ in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.isFlippedUpdated(strongSelf)
            }
        }

        if assumeReadyAfterTimeout {
            self.isReadyTimer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyUpdated()
                }
            }, queue: .mainQueue())
        }
        self.isReadyTimer?.start()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.isReadyTimer?.invalidate()
    }

    func animateRadialMask(from fromRect: CGRect, to toRect: CGRect) {
        let maskLayer = CAShapeLayer()
        maskLayer.frame = fromRect

        let path = CGMutablePath()
        path.addEllipse(in: CGRect(origin: CGPoint(), size: fromRect.size))
        maskLayer.path = path

        self.layer.mask = maskLayer

        let topLeft = CGPoint(x: 0.0, y: 0.0)
        let topRight = CGPoint(x: self.bounds.width, y: 0.0)
        let bottomLeft = CGPoint(x: 0.0, y: self.bounds.height)
        let bottomRight = CGPoint(x: self.bounds.width, y: self.bounds.height)

        func distance(_ v1: CGPoint, _ v2: CGPoint) -> CGFloat {
            let dx = v1.x - v2.x
            let dy = v1.y - v2.y
            return sqrt(dx * dx + dy * dy)
        }

        var maxRadius = distance(toRect.center, topLeft)
        maxRadius = max(maxRadius, distance(toRect.center, topRight))
        maxRadius = max(maxRadius, distance(toRect.center, bottomLeft))
        maxRadius = max(maxRadius, distance(toRect.center, bottomRight))
        maxRadius = ceil(maxRadius)

        let targetFrame = CGRect(origin: CGPoint(x: toRect.center.x - maxRadius, y: toRect.center.y - maxRadius), size: CGSize(width: maxRadius * 2.0, height: maxRadius * 2.0))

        let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
        transition.updatePosition(layer: maskLayer, position: targetFrame.center)
        transition.updateTransformScale(layer: maskLayer, scale: maxRadius * 2.0 / fromRect.width, completion: { [weak self] _ in
            self?.layer.mask = nil
        })
    }

    func updateLayout(size: CGSize, layoutMode: VideoNodeLayoutMode, transition: ContainedViewLayoutTransition) {
        self.updateLayout(size: size, cornerRadius: self.currentCornerRadius, isOutgoing: true, deviceOrientation: .portrait, isCompactLayout: false, transition: transition)
    }

    func updateLayout(size: CGSize, cornerRadius: CGFloat, isOutgoing: Bool, deviceOrientation: UIDeviceOrientation, isCompactLayout: Bool, transition: ContainedViewLayoutTransition) {
        self.currentCornerRadius = cornerRadius

        var rotationAngle: CGFloat
        if false && isOutgoing && isCompactLayout {
            rotationAngle = CGFloat.pi / 2.0
        } else {
            switch self.currentOrientation {
            case .rotation0:
                rotationAngle = 0.0
            case .rotation90:
                rotationAngle = CGFloat.pi / 2.0
            case .rotation180:
                rotationAngle = CGFloat.pi
            case .rotation270:
                rotationAngle = -CGFloat.pi / 2.0
            }

            var additionalAngle: CGFloat = 0.0
            switch deviceOrientation {
            case .portrait:
                additionalAngle = 0.0
            case .landscapeLeft:
                additionalAngle = CGFloat.pi / 2.0
            case .landscapeRight:
                additionalAngle = -CGFloat.pi / 2.0
            case .portraitUpsideDown:
                rotationAngle = CGFloat.pi
            default:
                additionalAngle = 0.0
            }
            rotationAngle += additionalAngle
            if abs(rotationAngle - CGFloat.pi * 3.0 / 2.0) < 0.01 {
                rotationAngle = -CGFloat.pi / 2.0
            }
            if abs(rotationAngle - (-CGFloat.pi)) < 0.01 {
                rotationAngle = -CGFloat.pi + 0.001
            }
        }

        let rotateFrame = abs(rotationAngle.remainder(dividingBy: CGFloat.pi)) > 1.0
        let fittingSize: CGSize
        if rotateFrame {
            fittingSize = CGSize(width: size.height, height: size.width)
        } else {
            fittingSize = size
        }

        let unboundVideoSize = CGSize(width: self.currentAspect * 10000.0, height: 10000.0)

        var fittedVideoSize = unboundVideoSize.fitted(fittingSize)
        if fittedVideoSize.width < fittingSize.width || fittedVideoSize.height < fittingSize.height {
            let isVideoPortrait = unboundVideoSize.width < unboundVideoSize.height
            let isFittingSizePortrait = fittingSize.width < fittingSize.height

            if isCompactLayout && isVideoPortrait == isFittingSizePortrait {
                fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
            } else {
                let maxFittingEdgeDistance: CGFloat
                if isCompactLayout {
                    maxFittingEdgeDistance = 200.0
                } else {
                    maxFittingEdgeDistance = 400.0
                }
                if fittedVideoSize.width > fittingSize.width - maxFittingEdgeDistance && fittedVideoSize.height > fittingSize.height - maxFittingEdgeDistance {
                    fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
                }
            }
        }

        let rotatedVideoHeight: CGFloat = max(fittedVideoSize.height, fittedVideoSize.width)

        let videoFrame: CGRect = CGRect(origin: CGPoint(), size: fittedVideoSize)

        let videoPausedSize = self.videoPausedNode.updateLayout(CGSize(width: size.width - 16.0, height: 100.0))
        transition.updateFrame(node: self.videoPausedNode, frame: CGRect(origin: CGPoint(x: floor((size.width - videoPausedSize.width) / 2.0), y: floor((size.height - videoPausedSize.height) / 2.0)), size: videoPausedSize))

        self.videoTransformContainer.bounds = CGRect(origin: CGPoint(), size: videoFrame.size)
        if transition.isAnimated && !videoFrame.height.isZero, let previousVideoHeight = self.previousVideoHeight, !previousVideoHeight.isZero {
            let scaleDifference = previousVideoHeight / rotatedVideoHeight
            if abs(scaleDifference - 1.0) > 0.001 {
                transition.animateTransformScale(view: self.videoTransformContainer, from: scaleDifference)
            }
        }
        self.previousVideoHeight = rotatedVideoHeight
        transition.updatePosition(view: self.videoTransformContainer, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformRotation(view: self.videoTransformContainer, angle: rotationAngle)

        let localVideoFrame = CGRect(origin: CGPoint(), size: videoFrame.size)
        self.videoView.view.bounds = localVideoFrame
        self.videoView.view.center = localVideoFrame.center
        // TODO: properly fix the issue
        // On iOS 13 and later metal layer transformation is broken if the layer does not require compositing
        self.videoView.view.alpha = 0.995

        if let effectView = self.effectView {
            transition.updateFrame(view: effectView, frame: localVideoFrame)
        }

        transition.updateCornerRadius(layer: self.layer, cornerRadius: self.currentCornerRadius)
    }

    func updateIsBlurred(isBlurred: Bool, light: Bool = false, animated: Bool = true) {
        if self.hasScheduledUnblur {
            self.hasScheduledUnblur = false
        }
        if self.isBlurred == isBlurred {
            return
        }
        self.isBlurred = isBlurred

        if isBlurred {
            if self.effectView == nil {
                let effectView = UIVisualEffectView()
                self.effectView = effectView
                effectView.frame = self.videoTransformContainer.bounds
                self.videoTransformContainer.addSubview(effectView)
            }
            if animated {
                UIView.animate(withDuration: 0.3, animations: {
                    self.videoPausedNode.alpha = 1.0
                    self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
                })
            } else {
                self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
            }
        } else if let effectView = self.effectView {
            self.effectView = nil
            UIView.animate(withDuration: 0.3, animations: {
                self.videoPausedNode.alpha = 0.0
                effectView.effect = nil
            }, completion: { [weak effectView] _ in
                effectView?.removeFromSuperview()
            })
        }
    }

    private var hasScheduledUnblur = false
    func flip(withBackground: Bool) {
        if withBackground {
            self.backgroundColor = .black
        }
        UIView.transition(with: withBackground ? self.videoTransformContainer : self, duration: 0.4, options: [.transitionFlipFromLeft, .curveEaseOut], animations: {
            UIView.performWithoutAnimation {
                self.updateIsBlurred(isBlurred: true, light: false, animated: false)
            }
        }) { finished in
            self.backgroundColor = nil
            self.hasScheduledUnblur = true
            Queue.mainQueue().after(0.5) {
                if self.hasScheduledUnblur {
                    self.updateIsBlurred(isBlurred: false)
                }
            }
        }
    }
}

private func interpolateFrame(from fromValue: CGRect, to toValue: CGRect, t: CGFloat) -> CGRect {
    return CGRect(x: floorToScreenPixels(toValue.origin.x * t + fromValue.origin.x * (1.0 - t)), y: floorToScreenPixels(toValue.origin.y * t + fromValue.origin.y * (1.0 - t)), width: floorToScreenPixels(toValue.size.width * t + fromValue.size.width * (1.0 - t)), height: floorToScreenPixels(toValue.size.height * t + fromValue.size.height * (1.0 - t)))
}

private func interpolate(from: CGFloat, to: CGFloat, value: CGFloat) -> CGFloat {
    return (1.0 - value) * from + value * to
}