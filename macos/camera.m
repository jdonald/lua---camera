//==============================================================================
// Description: A wrapper for Mac OS's camera API
//
// Created: January 12, 2012, 10:21AM
//
// Author: Clement Farabet
//==============================================================================

#include <luaT.h>
#include <TH.h>

#include <stdio.h>
#include <sys/time.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <signal.h>

#include <camera.h>

@interface ImageSnap()
- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
     fromConnection:(AVCaptureConnection *)connection;

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
     fromConnection:(AVCaptureConnection *)connection;

@end

@implementation ImageSnap

- (id)init{
  self = [super init];
  mCaptureSession = nil;
  mCaptureDeviceInput = nil;
  mCaptureDecompressedVideoOutput = nil;
  mCurrentImageBuffer = nil;
  return self;
}

- (void)dealloc{

  if( mCaptureSession )                                 [mCaptureSession release];
  if( mCaptureDeviceInput )                             [mCaptureDeviceInput release];
  if( mCaptureDecompressedVideoOutput ) [mCaptureDecompressedVideoOutput release];
  CVBufferRelease(mCurrentImageBuffer);

  [super dealloc];
}


// Returns an array of video devices attached to this computer.
+ (NSArray *)videoDevices{
  NSMutableArray *results = [NSMutableArray arrayWithCapacity:3];
  [results addObjectsFromArray:[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]];
  [results addObjectsFromArray:[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed]];
  return results;
}

// Returns the default video device or nil if none found.
+ (AVCaptureDevice *)defaultVideoDevice{
  AVCaptureDevice *device = nil;

  device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if( device == nil ){
    device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeMuxed];
  }
  return device;
}

// Returns the named capture device or nil if not found.
+(AVCaptureDevice *)deviceNamed:(NSString *)name{
  AVCaptureDevice *result = nil;

  NSArray *devices = [ImageSnap videoDevices];
  for( AVCaptureDevice *device in devices ){
    if ( [name isEqualToString:[device description]] ){
      result = device;
    }   // end if: match
  }   // end for: each device

  return result;
}   // end


// Saves an image to a file or standard out if path is nil or "-" (hyphen).
+ (BOOL) saveImage:(NSImage *)image toPath: (NSString*)path{

  NSString *ext = [path pathExtension];
  NSData *photoData = [ImageSnap dataFrom:image asType:ext];

  // If path is a dash, that means write to standard out
  if( path == nil || [@"-" isEqualToString:path] ){
    NSUInteger length = [photoData length];
    NSUInteger i;
    char *start = (char *)[photoData bytes];
    for( i = 0; i < length; ++i ){
      putc( start[i], stdout );
    }   // end for: write out
    return YES;
  } else {
    return [photoData writeToFile:path atomically:NO];
  }


  return NO;
}


/**
 * Converts an NSImage into NSData. Defaults to jpeg if
 * format cannot be determined.
 */
+(NSData *)dataFrom:(NSImage *)image asType:(NSString *)format{

  NSData *tiffData = [image TIFFRepresentation];

  NSBitmapImageFileType imageType = NSJPEGFileType;
  NSDictionary *imageProps = nil;


  // TIFF. Special case. Can save immediately.
  if( [@"tif"  rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [@"tiff" rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ){
    return tiffData;
  }

  // JPEG
  else if( [@"jpg"  rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [@"jpeg" rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ){
    imageType = NSJPEGFileType;
    imageProps = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.9] forKey:NSImageCompressionFactor];

  }

  // PNG
  else if( [@"png" rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ){
    imageType = NSPNGFileType;
  }

  // BMP
  else if( [@"bmp" rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ){
    imageType = NSBMPFileType;
  }

  // GIF
  else if( [@"gif" rangeOfString:format options:NSCaseInsensitiveSearch].location != NSNotFound ){
    imageType = NSGIFFileType;
  }

  NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:tiffData];
  NSData *photoData = [imageRep representationUsingType:imageType properties:imageProps];

  return photoData;
}   // end dataFrom

/**
 * Returns current snapshot or nil if there is a problem
 * or session is not started.
 */
-(CIImage *)snapshot{
  verbose( "Taking snapshot...\n");

  CVImageBufferRef frame = nil;               // Hold frame we find
  while( frame == nil ){                      // While waiting for a frame

    //verbose( "\tEntering synchronized block to see if frame is captured yet...");
    @synchronized(self){                    // Lock since capture is on another thread
      frame = mCurrentImageBuffer;        // Hold current frame
      CVBufferRetain(frame);              // Retain it (OK if nil)
    }   // end sync: self
    //verbose( "Done.\n" );

    if( frame == nil ){                     // Still no frame? Wait a little while.
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow: 0.1]];
    }

  }

  // Convert frame to an NSImage
  NSCIImageRep *imageRep = [NSCIImageRep imageRepWithCIImage:[CIImage imageWithCVImageBuffer:frame]];
  CIImage *image = [imageRep CIImage];
  [imageRep release];

  return image;
}




/**
 * Blocks until session is stopped.
 */
-(void)stopSession{
  verbose("Stopping session...\n" );

  // Make sure we've stopped
  while( mCaptureSession != nil ){
    verbose("\tCaptureSession != nil\n");

    verbose("\tStopping CaptureSession...");
    [mCaptureSession stopRunning];
    verbose("Done.\n");

    if( [mCaptureSession isRunning] ){
      verbose( "[mCaptureSession isRunning]");
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow: 0.1]];
    }else {
      verbose( "\tShutting down 'stopSession(..)'" );
      if( mCaptureSession )                                     [mCaptureSession release];
      if( mCaptureDeviceInput )                         [mCaptureDeviceInput release];
      if( mCaptureDecompressedVideoOutput )     [mCaptureDecompressedVideoOutput release];

      mCaptureSession = nil;
      mCaptureDeviceInput = nil;
      mCaptureDecompressedVideoOutput = nil;
    }   // end if: stopped

  }   // end while: not stopped
}


/**
 * Begins the capture session. Frames begin coming in.
 */
-(BOOL)startSession:(AVCaptureDevice *)device
          withWidth:(unsigned int)width
         withHeight:(unsigned int)height
{

  verbose( "Starting capture session...\n" );

  if( device == nil ) {
    verbose( "\tCannot start session: no device provided.\n" );
    return NO;
  }

  NSError *error = nil;

  // If we've already started with this device, return
  if( [device isEqual:[mCaptureDeviceInput device]] &&
      mCaptureSession != nil &&
      [mCaptureSession isRunning] ){
    return YES;
  }   // end if: already running

  else if( mCaptureSession != nil ){
    verbose( "\tStopping previous session.\n" );
    [self stopSession];
  }   // end if: else stop session


  // Create the capture session
  verbose( "\tCreating AVCaptureSession..." );
  mCaptureSession = [[AVCaptureSession alloc] init];
  verbose( "Done.\n");

  // Create input object from the device
  verbose( "\tCreating AVCaptureDeviceInput with %s...", [[device description] UTF8String] );
  mCaptureDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
  if (!mCaptureDeviceInput) {
    error( "\tCould not convert device to input device.\n");
    [mCaptureSession release];
    [mCaptureDeviceInput release];
    mCaptureSession = nil;
    mCaptureDeviceInput = nil;
    return NO;
  }
  [mCaptureSession addInput:mCaptureDeviceInput];
  verbose( "Done.\n");

  // Decompressed video output
  verbose( "\tCreating AVCaptureVideoDataOutput...");
  mCaptureDecompressedVideoOutput = [[AVCaptureVideoDataOutput alloc] init];

  if (!mCaptureDecompressedVideoOutput) {
    error( "\tCould not create decompressed output.\n");
    [mCaptureSession release];
    [mCaptureDeviceInput release];
    [mCaptureDecompressedVideoOutput release];
    mCaptureSession = nil;
    mCaptureDeviceInput = nil;
    mCaptureDecompressedVideoOutput = nil;
    return NO;
  }
  [mCaptureSession addOutput:mCaptureDecompressedVideoOutput];

  dispatch_queue_t queue = dispatch_queue_create("myQueue", NULL);
  [mCaptureDecompressedVideoOutput setSampleBufferDelegate:self queue:queue];
  dispatch_release(queue);
  verbose( "Done.\n" );

  NSDictionary *newSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB) };
  mCaptureDecompressedVideoOutput.videoSettings = newSettings;

  // Clear old image?
  verbose("\tEntering synchronized block to clear memory...");
  @synchronized(self){
    if( mCurrentImageBuffer != nil ){
      CVBufferRelease(mCurrentImageBuffer);
      mCurrentImageBuffer = nil;
    }   // end if: clear old image
  }   // end sync: self
  verbose( "Done.\n");

  [mCaptureSession startRunning];
  verbose("Session started.\n");

  return YES;
}   // end startSession



// This delegate method is called whenever the AVCaptureVideoDataOutput receives a frame
- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
     fromConnection:(AVCaptureConnection *)connection;
{
  verbose( "." );

  // Swap out old frame for new one
  CVImageBufferRef videoFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVImageBufferRef imageBufferToRelease;
  CVBufferRetain(videoFrame);

  @synchronized(self){
    imageBufferToRelease = mCurrentImageBuffer;
    mCurrentImageBuffer = videoFrame;
  }   // end sync
  CVBufferRelease(imageBufferToRelease);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
  fromConnection:(AVCaptureConnection *)connection;
{
  verbose( "." );
  verbose( "'nil' (dropped) Frame captured.\n" );
}

@end

// forward declaration
int releaseCameras(lua_State *L);

// static vars
static int nbcams = 0;
static ImageSnap **snap = NULL;
static AVCaptureDevice **device = NULL;
static NSAutoreleasePool * pool = NULL;

// start up all cameras found
int initCameras(lua_State *L) {
  // free cams
  if (nbcams > 0) {
    releaseCameras(L);
  }

  // pool
  if (pool == NULL) {
    pool = [[NSAutoreleasePool alloc] init];
  }

  // get args
  nbcams = lua_objlen(L, 1);
  int width = lua_tonumber(L, 2);
  int height = lua_tonumber(L, 3);

  // find devices
  NSArray *deviceName = [ImageSnap videoDevices];
  int k = 0;
  if ([deviceName count] > 0) {
    printf("found %ld video device(s):\n", [deviceName count]);
    for( AVCaptureDevice *name in deviceName ){
      printf( "%d: %s\n", k++, [[name description] UTF8String] );
    }
  } else {
    printf("no video devices found, aborting...\n");
    return 0;
  }

  // init given cameras
  printf("user requested %d camera(s)\n", nbcams);
  if ([deviceName count] < nbcams) {
    nbcams = [deviceName count];
    printf("only using the first %d camera(s)\n", nbcams);
  }
  device = malloc(sizeof(AVCaptureDevice *)*nbcams);
  int i = 0, j = 0;
  for( AVCaptureDevice *dev in deviceName ) {
    // next cam:
    for (int k=1; k<=nbcams; k++) {
      lua_rawgeti(L, 1, k);
      int user = lua_tonumber(L, -1);
      if (user == j) {
        device[i++] = [ImageSnap deviceNamed:[dev description]];
        printf( "using device %d: %s\n", j, [[dev description] UTF8String] );
      }
      lua_pop(L, 1);
    }
    j++;
  }

  // start snapshots
  snap = malloc(sizeof(ImageSnap *)*nbcams);
  for (int i=0; i<nbcams; i++) {
    snap[i] = [[ImageSnap alloc] init];
    if( [snap[i] startSession:device[i] withWidth:width withHeight:height] ) {
      printf("device %d started.\n", i);
    }
  }

  // warmup
  double delay = 1.0;
  verbose("delaying %.2lf seconds for warmup...", delay);
  NSDate *now = [[NSDate alloc] init];
  [[NSRunLoop currentRunLoop] runUntilDate:[now dateByAddingTimeInterval: delay]];
  [now release];
  verbose("warmup complete.\n");

  // done
  lua_pushnumber(L, nbcams);
  return 1;
}

// grab next frame
int grabFrame(lua_State *L) {

  // get next tensor
  const int idx = lua_tonumber(L, 1);
  THFloatTensor * tensor = luaT_toudata(L, 2, "torch.FloatTensor");

  // grab frame
  verbose("grabbing image %d\n", idx);
  CIImage *image = [snap[idx] snapshot];
  verbose("grabbed\n");

  // export to bitmap
  NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCIImage:image];

  // get info
  NSSize size = [imageRep size];
  int bytesPerRow = [imageRep bytesPerRow];
  unsigned char *bytes = [imageRep bitmapData];

  // resize dest
  long width = size.width;
  long height = size.height;
  THFloatTensor_resize3d(tensor, 3, height, width);

  // copy pixels to tensor
  float *dst = THFloatTensor_data(tensor);
  int m0 = tensor->stride[1];
  int m1 = tensor->stride[2];
  int m2 = tensor->stride[0];
  int i, j, k;
  const int nChannels = [imageRep samplesPerPixel];
  for (i = 0; i < height; i++) {
      for (j = 0, k = 0; j < width; j++, k+= m1) {
          dst[k]      = bytes[i*bytesPerRow + j*nChannels + 2]/255.;
          dst[k+m2]   = bytes[i*bytesPerRow + j*nChannels + 1]/255.;
          dst[k+2*m2] = bytes[i*bytesPerRow + j*nChannels + 0]/255.;
      }
      dst += m0;
  }

  // cleanup
  [imageRep release];
  [image release];

  // done
  return 0;
}

// stop camers
int releaseCameras(lua_State *L) {
  if (snap == NULL) {
    return 0;
  }
  for (int i=0; i<nbcams; i++) {
    [snap[i] release];
    [device[i] release];
  }
  free(device);
  nbcams = 0;
  snap = NULL;
  return 0;
}

// Register functions into lua space
static const struct luaL_reg cammacos [] = {
  {"initCameras", initCameras},
  {"grabFrame", grabFrame},
  {"releaseCameras", releaseCameras},
  {NULL, NULL}  /* sentinel */
};

int luaopen_libcammacos (lua_State *L) {
  luaL_openlib(L, "libcammacos", cammacos, 0);
  return 1;
}
