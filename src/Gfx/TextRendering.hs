{-# LANGUAGE TemplateHaskell #-}

module Gfx.TextRendering
  ( createTextRenderer
  , renderText
  , renderTextToBuffer
  , addCodeTextureToLib
  , resizeTextRendererScreen
  , changeTextColour
  , TextRenderer
  ) where

import           Control.Monad                  ( foldM_ )
import           Data.Maybe                     ( listToMaybe )

import           Foreign.Marshal.Array          ( withArray )
import           Foreign.Marshal.Utils          ( fromBool
                                                , with
                                                )
import           Foreign.Ptr                    ( castPtr
                                                , nullPtr
                                                )
import           Foreign.Storable               ( sizeOf )

import           Data.FileEmbed                 ( embedFile )
import           Gfx.FontHandling               ( Character(..)
                                                , Font(..)
                                                , getCharacter
                                                , loadFont
                                                )
import           Gfx.LoadShaders                ( ShaderInfo(..)
                                                , ShaderSource(..)
                                                , loadShaders
                                                )
import           Gfx.OpenGL                     ( colToGLCol
                                                , printErrors
                                                )
import           Gfx.Types                      ( Colour(..) )
import           Gfx.VertexBuffers              ( VBO(..)
                                                , createVBO
                                                , drawVBO
                                                , setAttribPointer
                                                )
import qualified Graphics.GL                   as GLRaw
import           Graphics.Rendering.OpenGL      ( ($=)
                                                , AttribLocation(..)
                                                , BlendEquation(FuncAdd)
                                                , BlendingFactor
                                                  ( One
                                                  , OneMinusSrcAlpha
                                                  , SrcAlpha
                                                  , Zero
                                                  )
                                                , BufferTarget(ArrayBuffer)
                                                , BufferUsage(DynamicDraw)
                                                , Capability(Enabled)
                                                , ClearBuffer(ColorBuffer)
                                                , FramebufferTarget(Framebuffer)
                                                , GLfloat
                                                , PrimitiveMode(Triangles)
                                                , Program
                                                , ShaderType
                                                  ( FragmentShader
                                                  , VertexShader
                                                  )
                                                , TextureTarget2D(Texture2D)
                                                , TextureUnit(..)
                                                , TransferDirection
                                                  ( WriteToBuffer
                                                  )
                                                , UniformLocation(..)
                                                )
import qualified Graphics.Rendering.OpenGL     as GL

import           Gfx.PostProcessing             ( Savebuffer(..)
                                                , createTextDisplaybuffer
                                                , deleteSavebuffer
                                                )
import           Gfx.Textures                   ( TextureLibrary
                                                , addTexture
                                                )

import           Gfx.Matrices                   ( orthographicMat
                                                , translateMat
                                                )
import           Linear.Matrix                  ( (!*!)
                                                , M44
                                                )

import           Configuration                  ( ImprovizConfig )
import qualified Configuration                 as C
import qualified Configuration.Font            as FC
import qualified Configuration.Screen          as CS
import           Lens.Simple                    ( (^.) )

data TextRenderer = TextRenderer
  { textFont        :: Font
  , textAreaHeight  :: Int
  , pMatrix         :: M44 GLfloat
  , textprogram     :: Program
  , bgprogram       :: Program
  , characterQuad   :: VBO
  , characterBGQuad :: VBO
  , textColour      :: Colour
  , textBGColour    :: Colour
  , outbuffer       :: Savebuffer
  }
  deriving Show

textCoordMatrix :: Floating f => f -> f -> f -> f -> f -> f -> M44 f
textCoordMatrix left right top bottom near far =
  let o = orthographicMat left right top bottom near far
      t = translateMat (-1) 1 0
  in  t !*! o

createCharacterTextQuad :: IO VBO
createCharacterTextQuad =
  let vertexSize    = fromIntegral $ sizeOf (0 :: GLfloat)
      posVSize      = 2
      texVSize      = 2
      numVertices   = 6
      firstPosIndex = 0
      firstTexIndex = posVSize * vertexSize
      vPosition     = AttribLocation 0
      vTexCoord     = AttribLocation 1
      numElements   = numVertices * (posVSize + texVSize)
      size          = fromIntegral (numElements * vertexSize)
      stride        = fromIntegral ((posVSize + texVSize) * vertexSize)
      quadConfig    = do
        GL.bufferData ArrayBuffer $= (size, nullPtr, DynamicDraw)
        setAttribPointer vPosition posVSize stride firstPosIndex
        setAttribPointer vTexCoord texVSize stride firstTexIndex
  in  createVBO [quadConfig] Triangles firstPosIndex numVertices

createCharacterBGQuad :: IO VBO
createCharacterBGQuad =
  let vertexSize    = fromIntegral $ sizeOf (0 :: GLfloat)
      posVSize      = 2
      numVertices   = 6
      firstPosIndex = 0
      vPosition     = AttribLocation 0
      numElements   = numVertices * posVSize
      size          = fromIntegral (numElements * vertexSize)
      stride        = 0
      quadConfig    = do
        GL.bufferData ArrayBuffer $= (size, nullPtr, DynamicDraw)
        setAttribPointer vPosition posVSize stride firstPosIndex
  in  createVBO [quadConfig] Triangles firstPosIndex numVertices

createTextRenderer :: ImprovizConfig -> Int -> Int -> Float -> IO TextRenderer
createTextRenderer config width height scaling =
  let front = config ^. C.screen . CS.front
      back = config ^. C.screen . CS.back
   in do cq <- createCharacterTextQuad
         cbq <- createCharacterBGQuad
         tprogram <-
           loadShaders
             [ ShaderInfo
                 VertexShader
                 (ByteStringSource
                    $(embedFile "src/assets/shaders/textrenderer.vert"))
             , ShaderInfo
                 FragmentShader
                 (ByteStringSource
                    $(embedFile "src/assets/shaders/textrenderer.frag"))
             ]
         bgshaderprogram <-
           loadShaders
             [ ShaderInfo
                 VertexShader
                 (ByteStringSource
                    $(embedFile "src/assets/shaders/textrenderer-bg.vert"))
             , ShaderInfo
                 FragmentShader
                 (ByteStringSource
                    $(embedFile "src/assets/shaders/textrenderer-bg.frag"))
             ]
         font <-
           loadFont
             (config ^. C.fontConfig . FC.filepath)
             (round (fromIntegral (config ^. C.fontConfig . FC.size) / scaling))
         let projectionMatrix =
               textCoordMatrix
                 0
                 (fromIntegral width)
                 0
                 (fromIntegral height)
                 front
                 back
         buffer <-
           createTextDisplaybuffer (fromIntegral width) (fromIntegral height)
         return $
           TextRenderer
             font
             height
             projectionMatrix
             tprogram
             bgshaderprogram
             cq
             cbq
             (config ^. C.fontConfig . FC.fgColour)
             (config ^. C.fontConfig . FC.bgColour)
             buffer

addCodeTextureToLib :: TextRenderer -> TextureLibrary -> TextureLibrary
addCodeTextureToLib tr tlib =
  let (Savebuffer _ text _ _ _) = outbuffer tr in addTexture tlib "code" text

resizeTextRendererScreen
  :: ImprovizConfig -> Int -> Int -> TextRenderer -> IO TextRenderer
resizeTextRendererScreen config width height trender =
  let
    front = config ^. C.screen . CS.front
    back  = config ^. C.screen . CS.back
    projectionMatrix =
      textCoordMatrix 0 (fromIntegral width) 0 (fromIntegral height) front back
  in
    do
      deleteSavebuffer $ outbuffer trender
      nbuffer <- createTextDisplaybuffer (fromIntegral width)
                                         (fromIntegral height)
      return trender { pMatrix = projectionMatrix, outbuffer = nbuffer }

changeTextColour :: Colour -> TextRenderer -> TextRenderer
changeTextColour newColour trender = trender { textColour = newColour }

renderText :: Int -> Int -> TextRenderer -> String -> IO ()
renderText xpos ypos renderer strings =
  let (Savebuffer fbo _ _ _ _) = outbuffer renderer
      height                   = textAreaHeight renderer
  in  do
        GL.bindFramebuffer Framebuffer $= fbo
        renderCharacters xpos (height - ypos) renderer strings
        printErrors

renderTextToBuffer :: TextRenderer -> IO ()
renderTextToBuffer renderer = do
  GL.bindFramebuffer Framebuffer $= GL.defaultFramebufferObject
  let (Savebuffer _ text _ program quadVBO) = outbuffer renderer
  GL.currentProgram $= Just program
  GL.activeTexture $= TextureUnit 0
  GL.textureBinding Texture2D $= Just text
  drawVBO quadVBO

renderCharacters :: Int -> Int -> TextRenderer -> String -> IO ()
renderCharacters xpos ypos renderer strings = do
  GL.blend $= Enabled
  GL.blendEquationSeparate $= (FuncAdd, FuncAdd)
  GL.blendFuncSeparate $= ((SrcAlpha, OneMinusSrcAlpha), (One, Zero))
  GL.depthFunc $= Nothing
  GL.clearColor $= colToGLCol (Colour 0.0 0.0 0.0 0.0)
  GL.clear [ColorBuffer]
  let font = textFont renderer
  foldM_
    (\(xp, yp) c -> case c of
      '\n' -> return (xpos, yp - fontHeight font)
      '\t' -> renderCharacterSpace renderer (fontAdvance font) xp yp font
      _    -> maybe (return (xp, yp - fontAdvance font))
                    (\c -> renderChar c xp yp font)
                    (getCharacter font c)
    )
    (xpos, ypos)
    strings
 where
  renderChar char xp yp f = do
    renderCharacterBGQuad renderer char xp yp f
    renderCharacterTextQuad renderer char xp yp f

sendProjectionMatrix :: Program -> M44 GLfloat -> IO ()
sendProjectionMatrix program mat = do
  (UniformLocation projU) <- GL.get $ GL.uniformLocation program "projection"
  with mat $ GLRaw.glUniformMatrix4fv projU 1 (fromBool True) . castPtr

sendVertices :: [GLfloat] -> IO ()
sendVertices verts =
  let vertSize = sizeOf (head verts)
      numVerts = length verts
      size     = fromIntegral (numVerts * vertSize)
  in  withArray verts
        $ \ptr -> GL.bufferSubData ArrayBuffer WriteToBuffer 0 size ptr

renderCharacterQuad
  :: Program -> M44 GLfloat -> VBO -> IO () -> [GLfloat] -> IO ()
renderCharacterQuad program pMatrix character charDrawFunc charVerts =
  let (VBO arrayObject arrayBuffers primMode firstIndex numTriangles) =
        character
  in  do
        GL.currentProgram $= Just program
        GL.bindVertexArrayObject $= Just arrayObject
        GL.bindBuffer ArrayBuffer $= listToMaybe arrayBuffers
        charDrawFunc
        sendProjectionMatrix program pMatrix
        sendVertices charVerts
        GL.drawArrays primMode firstIndex numTriangles
        printErrors

renderCharacterTextQuad
  :: TextRenderer -> Character -> Int -> Int -> Font -> IO (Int, Int)
renderCharacterTextQuad renderer (Character c width height adv xBearing yBearing text) x y font
  = let
      baseline = fromIntegral (y - fontAscender font)
      gX1      = fromIntegral (x + xBearing)
      gX2      = gX1 + fromIntegral width
      gY1      = baseline + fromIntegral yBearing
      gY2      = gY1 - fromIntegral height
      charVerts =
        [ gX1
        , gY1
        , 0.0
        , 0.0 -- coord 1
        , gX1
        , gY2
        , 0.0
        , 1.0 -- coord 2
        , gX2
        , gY1
        , 1.0
        , 0.0 -- coord 3
        , gX1
        , gY2
        , 0.0
        , 1.0 -- coord 4
        , gX2
        , gY2
        , 1.0
        , 1.0 -- coord 5
        , gX2
        , gY1
        , 1.0
        , 0.0 -- coord 6
        ] :: [GLfloat]
      charDrawFunc = do
        GL.activeTexture $= TextureUnit 0
        GL.textureBinding Texture2D $= Just text
        textColourU <- GL.get
          $ GL.uniformLocation (textprogram renderer) "textColor"
        GL.uniform textColourU $= colToGLCol (textColour renderer)
        textBGColourU <- GL.get
          $ GL.uniformLocation (textprogram renderer) "textBGColor"
        GL.uniform textBGColourU $= colToGLCol (textBGColour renderer)
    in
      do
        renderCharacterQuad (textprogram renderer)
                            (pMatrix renderer)
                            (characterQuad renderer)
                            charDrawFunc
                            charVerts
        return (x + adv, y)

renderCharacterBGQuad
  :: TextRenderer -> Character -> Int -> Int -> Font -> IO (Int, Int)
renderCharacterBGQuad renderer (Character _ _ _ adv _ _ _) =
  renderCharacterSpace renderer adv

renderCharacterSpace
  :: TextRenderer -> Int -> Int -> Int -> Font -> IO (Int, Int)
renderCharacterSpace renderer adv x y font =
  let x1           = fromIntegral x
      x2           = fromIntegral $ x + adv
      y1           = fromIntegral y
      y2           = fromIntegral $ y - fontHeight font
      charVerts = [x1, y1, x1, y2, x2, y1, x1, y2, x2, y2, x2, y1] :: [GLfloat]
      charDrawFunc = do
        textBGColourU <- GL.get
          $ GL.uniformLocation (bgprogram renderer) "textBGColor"
        GL.uniform textBGColourU $= colToGLCol (textBGColour renderer)
  in  do
        renderCharacterQuad (bgprogram renderer)
                            (pMatrix renderer)
                            (characterBGQuad renderer)
                            charDrawFunc
                            charVerts
        return (x + adv, y)
