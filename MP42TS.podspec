Pod::Spec.new do |s|
  s.name             = 'MP42TS'
  s.version          = '0.1.4'
  s.summary          = 'MP42TS allows you to convert MP4 files to TS files.'

  s.description      = <<-DESC
MP42TS allows you to convert MP4 files into TS files. This library depends on libgpac (http://gpac.wp.mines-telecom.fr/) distributed as a Pod (GPAC4iOS).
                       DESC

  s.homepage         = 'https://github.com/hongrich/MP42TS'
  s.author           = { 'Rich Hong' => 'hong.rich@gmail.com' }
  s.source           = { :git => 'https://github.com/hongrich/MP42TS.git', :tag => s.version.to_s }

  s.ios.deployment_target = '8.0'

  s.source_files = 'MP42TS/Classes/**/*'
  s.dependency 'GPAC4iOS'
end
