//
//  RingBuffer.m
//  MyPlaythrough
//
//  Created by kyab on 2017/05/16.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "RingBuffer.h"
#import "mach/mach.h"

@implementation RingBuffer
- (id)init{
    self = [super init];
    
    [self initBuffers];
    
    _minOffsetFrame = 64;
    return self;
    
}


-(BOOL)initBuffers{
    _leftBuf = [self allocMirrorBuf2:RING_SIZE_SAMPLE*4];
    if (!_leftBuf){
        return NO;
    }
    _rightBuf = [self allocMirrorBuf2:RING_SIZE_SAMPLE*4];
    if (!_rightBuf){
        return NO;
    }
    
    NSLog(@"Buffer allocation OK, left=%p, right=%p", _leftBuf, _rightBuf);
    return YES;
}


//https://github.com/michaeltyson/TPCircularBuffer/blob/master/TPCircularBuffer.c#L55
//

-(void *)allocMirrorBuf:(size_t) byteSize{
    // Keep trying until we get our buffer, needed to handle race conditions
    int retries = 3;
    while ( true ) {
        
        int32_t size = (int32_t)round_page(byteSize);    // We need whole page sizes
        
        // Temporarily allocate twice the length, so we have the contiguous address space to
        // support a second instance of the buffer directly after
        vm_address_t bufferAddress;
        kern_return_t result = vm_allocate(mach_task_self(),
                                           &bufferAddress,
                                           size * 2,
                                           VM_FLAGS_ANYWHERE); // allocate anywhere it'll fit
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Buffer allocation");
                return 0;
            }
            // Try again if we fail
            continue;
        }
        
        // Now replace the second half of the allocation with a virtual copy of the first half. Deallocate the second half...
        result = vm_deallocate(mach_task_self(),
                               bufferAddress + size,
                               size);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Buffer deallocation");
                return 0;
            }
            // If this fails somehow, deallocate the whole region and try again
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        
        // Re-map the buffer to the address space immediately after the buffer
        vm_address_t virtualAddress = bufferAddress + size;
        vm_prot_t cur_prot, max_prot;
        result = vm_remap(mach_task_self(),
                          &virtualAddress,   // mirror target
                          size,    // size of mirror
                          0,                 // auto alignment
                          0,                 // force remapping to virtualAddress
                          mach_task_self(),  // same task
                          bufferAddress,     // mirror source
                          0,                 // MAP READ-WRITE, NOT COPY
                          &cur_prot,         // unused protection struct
                          &max_prot,         // unused protection struct
                          VM_INHERIT_DEFAULT);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Remap buffer memory");
                return 0;
            }
            // If this remap failed, we hit a race condition, so deallocate and try again
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        
        if ( virtualAddress != bufferAddress+size) {
            // If the memory is not contiguous, clean up both allocated buffers and try again
            if ( retries-- == 0 ) {
                printf("Couldn't map buffer memory to end of buffer\n");
                return false;
            }
            
            vm_deallocate(mach_task_self(), virtualAddress, size);
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        _bufSize = size;
         return (void *)bufferAddress;
    }
    return 0;
}


//mirror to pre address and post address to support reverse playback.
-(void *)allocMirrorBuf2:(size_t) byteSize{

    int retries = 6;
    while ( true ) {
        
        int32_t size = (int32_t)round_page(byteSize);
        
        vm_address_t bufferAddress;
        kern_return_t result = vm_allocate(mach_task_self(),
                                           &bufferAddress,
                                           size * 3,
                                           VM_FLAGS_ANYWHERE);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Buffer allocation");
                return NULL;
            }
            continue;
        }
        
        bufferAddress += size;
        
        result = vm_deallocate(mach_task_self(), bufferAddress + size, size);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Buffer deallocation");
                return NULL;
            }
            vm_deallocate(mach_task_self(), bufferAddress-size, size*2);
            continue;
        }
        
        result = vm_deallocate(mach_task_self(), bufferAddress-size, size);
        if ( result != ERR_SUCCESS ) {
            if (retries-- == 0){
                NSLog(@"Buffer deallocation");
                return NULL;
            }
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        
        vm_address_t virtualAddress = bufferAddress + size;
        vm_prot_t cur_prot, max_prot;
        result = vm_remap(mach_task_self(),
                          &virtualAddress,
                          size,
                          0,
                          0,
                          mach_task_self(),
                          bufferAddress,     // mirror source
                          0,
                          &cur_prot,
                          &max_prot,
                          VM_INHERIT_DEFAULT);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Remap buffer memory");
                return NULL;
            }
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        
        if (virtualAddress != bufferAddress + size){
            if (retries -- == 0){
                NSLog(@"COuldnt map buffer (post half)");
                return NULL;
            }
            vm_deallocate(mach_task_self(), bufferAddress, size);
            vm_deallocate(mach_task_self(), virtualAddress,size);
            continue;
        }
        
        virtualAddress = bufferAddress-size;
        result = vm_remap(mach_task_self(),
                          &virtualAddress,
                          size,
                          0,
                          0,
                          mach_task_self(),
                          bufferAddress,     // mirror source
                          0,
                          &cur_prot,
                          &max_prot,
                          VM_INHERIT_DEFAULT);
        if ( result != ERR_SUCCESS ) {
            if ( retries-- == 0 ) {
                NSLog(@"Remap buffer memory");
                return NULL;
            }
            vm_deallocate(mach_task_self(), bufferAddress+size, size);
            vm_deallocate(mach_task_self(), bufferAddress, size);
            continue;
        }
        
        if ( virtualAddress != bufferAddress - size) {
            if ( retries-- == 0 ) {
                NSLog(@"Couldn't map buffer memory to end of buffer");
                return NULL;
            }
            
            vm_deallocate(mach_task_self(), virtualAddress, size);
            vm_deallocate(mach_task_self(), bufferAddress + size, size);
            vm_deallocate(mach_task_self(), bufferAddress, size);
            
            continue;
        }
        _bufSize = size;
        
        //check
        UInt8 *p = (UInt8 *)bufferAddress;
        for (int i = 0-size ; i < size*2 ; i++){
            *(p + i) = 0;
        }
        
        return (void *)bufferAddress;
    }
    return NULL;
}




-(float *)writePtrLeft{
    return &_leftBuf[_recordFrame];
}

-(float *)writePtrRight{
    return &_rightBuf[_recordFrame];
}

-(void)advanceWritePtrSample:(SInt32)sample{
    UInt32 frames = [self frames];
    if (_recordFrame + sample > frames){
        _recordFrame = sample - (frames - _recordFrame);
    }else{
        _recordFrame += sample;
    }
}

-(float *)readPtrLeft{
    
    UInt32 w = _recordFrame;
    UInt32 r = _playFrame;
    
    if (w < r){
        if (w < 10000 && r > RING_SIZE_SAMPLE-10000){
            // rounding
            w += [self frames];
        }else{
            // reading before write.
            return NULL;
        }
    }
    UInt32 off = w-r;

    if (off >= _minOffsetFrame){
        return &_leftBuf[_playFrame];
    }else{
        // too near
        return NULL;
    }
}

-(float *)readPtrRight{
    UInt32 w = _recordFrame;
    UInt32 r = _playFrame;
    
    if (w < r){
        if (w < 10000 && r > RING_SIZE_SAMPLE-10000){
            // rounding
            w += [self frames];
        }else{
            // reading before write.
            return NULL;
        }
    }
    UInt32 off = w-r;
    
    if (off >= _minOffsetFrame){
        return &_rightBuf[_playFrame];
    }else{
        return NULL;
    }
}

-(float *)startPtrLeft{
    return _leftBuf;
}
-(float *)startPtrRight{
    return _rightBuf;
}

-(Boolean)isShortage{
    UInt32 w = _recordFrame;
    UInt32 r = _playFrame;
    
    if (w < r){
        w += [self frames];
    }
    UInt32 off = w-r;
    if (off >= _minOffsetFrame){
        return NO;
    }else{
        return YES;
    }
}

-(UInt32)advanceReadPtrSample:(SInt32)sample{
    SInt32 frames = [self frames];
    if ((SInt32)_playFrame + sample > frames){
        _playFrame = sample - (frames - _playFrame);
    }else if ((SInt32)_playFrame + sample < 0){
        _playFrame = frames - (sample*(-1) - _playFrame);
    }else{
        _playFrame += sample;
    }
    
    return _playFrame;
    
}

-(void)moveReadPtrToSample:(UInt32)sample{
    _playFrame = sample;
}

-(UInt32)readPtrDistanceFrom:(SInt32)sample{
    if (_playFrame >= sample){
        return (UInt32)(_playFrame - sample);
    }else{
        return (UInt32)([self frames] - sample) + (UInt32)_playFrame;
    }
}

-(void)resetBuffer{
    _playFrame = 0;
    _recordFrame = 0;
    bzero(_leftBuf,sizeof(float)*RING_SIZE_SAMPLE);
    bzero(_rightBuf,sizeof(float)*RING_SIZE_SAMPLE);
}

-(void)follow{
    
    if (0 > (SInt32)_recordFrame - _minOffsetFrame){
        _playFrame = [self frames] - (_minOffsetFrame - _recordFrame);
        
    }else{
        _playFrame = _recordFrame - _minOffsetFrame;
    }
//    NSLog(@"frames = %u, w = %u, r = %u", [self frames], _recordFrame, _playFrame);
}

-(UInt32)frames{
    return _bufSize / 4;
}

-(UInt32)bufSize{
    return _bufSize;
}


-(UInt32)recordFrame{
    return _recordFrame;
}
-(UInt32)playFrame{
    return _playFrame;
}


@end
