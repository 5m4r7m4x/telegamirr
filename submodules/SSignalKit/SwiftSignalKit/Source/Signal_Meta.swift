import Foundation

private final class SignalQueueState<T, E> {
    let lock = createOSUnfairLock()
    var executingSignal = false
    var terminated = false
    
    let currentDisposable: MetaDisposable
    var subscriber: Subscriber<T, E>?
    
    var queuedSignals: [Signal<T, E>] = []
    let queueMode: Bool
    let throttleMode: Bool
    
    init(subscriber: Subscriber<T, E>, queueMode: Bool, throttleMode: Bool, currentDisposable: MetaDisposable) {
        self.subscriber = subscriber
        self.queueMode = queueMode
        self.throttleMode = throttleMode
        self.currentDisposable = currentDisposable
    }
    
    deinit {
    }
    
    func enqueueSignal(_ signal: Signal<T, E>) {
        var startSignal = false
        self.lock.lock()
        if self.queueMode && self.executingSignal {
            if self.throttleMode {
                self.queuedSignals.removeAll()
            }
            self.queuedSignals.append(signal)
        } else {
            self.executingSignal = true
            startSignal = true
        }
        self.lock.unlock()
        
        if startSignal {
            let disposable = signal.start(next: { next in
                assert(self.subscriber != nil)
                self.subscriber?.putNext(next)
            }, error: { error in
                assert(self.subscriber != nil)
                self.subscriber?.putError(error)
            }, completed: {
                self.headCompleted()
            })
            self.currentDisposable.set(disposable)
        }
    }
    
    func headCompleted() {
        while true {
            let leftFunction = Atomic(value: false)
            
            var nextSignal: Signal<T, E>! = nil
            
            var terminated = false
            self.lock.lock()
            self.executingSignal = false
            if self.queueMode {
                if self.queuedSignals.count != 0 {
                    nextSignal = self.queuedSignals[0]
                    self.queuedSignals.remove(at: 0)
                    self.executingSignal = true
                } else {
                    terminated = self.terminated
                }
            } else {
                terminated = self.terminated
            }
            self.lock.unlock()
            
            if terminated {
                self.subscriber?.putCompletion()
            } else if nextSignal != nil {
                let disposable = nextSignal.start(next: { next in
                    assert(self.subscriber != nil)
                    self.subscriber?.putNext(next)
                }, error: { error in
                    assert(self.subscriber != nil)
                    self.subscriber?.putError(error)
                }, completed: {
                    if leftFunction.swap(true) == true {
                        self.headCompleted()
                    }
                })
                
                currentDisposable.set(disposable)
            }
            
            if leftFunction.swap(true) == false {
                break
            }
        }
    }
    
    func beginCompletion() {
        var executingSignal = false
        self.lock.lock()
        executingSignal = self.executingSignal
        self.terminated = true
        self.lock.unlock()
        
        if !executingSignal {
            self.subscriber?.putCompletion()
        }
    }
}

public func switchToLatest<T, E>(_ signal: Signal<Signal<T, E>, E>) -> Signal<T, E> {
    return Signal { subscriber in
        let currentDisposable = MetaDisposable()
        let state = SignalQueueState(subscriber: subscriber, queueMode: false, throttleMode: false, currentDisposable: currentDisposable)
        let disposable = signal.start(next: { next in
            state.enqueueSignal(next)
        }, error: { error in
            subscriber.putError(error)
        }, completed: {
            state.beginCompletion()
        })
        return ActionDisposable {
            currentDisposable.dispose()
            disposable.dispose()
        }
    }
}

public func queue<T, E>(_ signal: Signal<Signal<T, E>, E>) -> Signal<T, E> {
    return Signal { subscriber in
        let currentDisposable = MetaDisposable()
        let state = SignalQueueState(subscriber: subscriber, queueMode: true, throttleMode: false, currentDisposable: currentDisposable)
        let disposable = signal.start(next: { next in
            state.enqueueSignal(next)
        }, error: { error in
            subscriber.putError(error)
        }, completed: {
            state.beginCompletion()
        })
        return ActionDisposable {
            currentDisposable.dispose()
            disposable.dispose()
        }
    }
}

public func throttled<T, E>(_ signal: Signal<Signal<T, E>, E>) -> Signal<T, E> {
    return Signal { subscriber in
        let currentDisposable = MetaDisposable()
        let state = SignalQueueState(subscriber: subscriber, queueMode: true, throttleMode: true, currentDisposable: currentDisposable)
        let disposable = signal.start(next: { next in
            state.enqueueSignal(next)
        }, error: { error in
            subscriber.putError(error)
        }, completed: {
            state.beginCompletion()
        })
        return ActionDisposable {
            currentDisposable.dispose()
            disposable.dispose()
        }
    }
}

public func mapToSignal<T, R, E>(_ f: @escaping(T) -> Signal<R, E>) -> (Signal<T, E>) -> Signal<R, E> {
    return { signal -> Signal<R, E> in
        return Signal<Signal<R, E>, E> { subscriber in
            return signal.start(next: { next in
                subscriber.putNext(f(next))
            }, error: { error in
                subscriber.putError(error)
            }, completed: {
                subscriber.putCompletion()
            })
        } |> switchToLatest
    }
}

public func ignoreValues<T, E>(_ signal: Signal<T, E>) -> Signal<Never, E> {
    return Signal { subscriber in
        return signal.start(error: { error in
            subscriber.putError(error)
        }, completed: {
            subscriber.putCompletion()
        })
    }
}

public func mapToSignalPromotingError<T, R, E>(_ f: @escaping(T) -> Signal<R, E>) -> (Signal<T, NoError>) -> Signal<R, E> {
    return { signal -> Signal<R, E> in
        return Signal<Signal<R, E>, E> { subscriber in
            return signal.start(next: { next in
                subscriber.putNext(f(next))
            }, completed: { 
                subscriber.putCompletion()
            })
        } |> switchToLatest
    }
}

public func mapToQueue<T, R, E>(_ f: @escaping(T) -> Signal<R, E>) -> (Signal<T, E>) -> Signal<R, E> {
    return { signal -> Signal<R, E> in
        return signal |> map { f($0) } |> queue
    }
}

public func mapToThrottled<T, R, E>(_ f: @escaping(T) -> Signal<R, E>) -> (Signal<T, E>) -> Signal<R, E> {
    return { signal -> Signal<R, E> in
        return signal |> map { f($0) } |> throttled
    }
}

public func then<T, E>(_ nextSignal: Signal<T, E>) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal -> Signal<T, E> in
        return Signal<T, E> { subscriber in
            let disposable = DisposableSet()
            
            disposable.add(signal.start(next: { next in
                subscriber.putNext(next)
            }, error: { error in
                subscriber.putError(error)
            }, completed: {
                disposable.add(nextSignal.start(next: { next in
                    subscriber.putNext(next)
                }, error: { error in
                    subscriber.putError(error)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }))
            
            return disposable
        }
    }
}

public func deferred<T, E>(_ generator: @escaping() -> Signal<T, E>) -> Signal<T, E> {
    return Signal { subscriber in
        return generator().start(next: { next in
            subscriber.putNext(next)
        }, error: { error in
            subscriber.putError(error)
        }, completed: {
            subscriber.putCompletion()
        })
    }
}
