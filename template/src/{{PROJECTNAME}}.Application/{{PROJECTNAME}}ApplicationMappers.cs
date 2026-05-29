// ${PROJECT_NAME}ApplicationMappers.cs — Mapperly mapper registry placeholder.
//
// This codebase uses Mapperly for DTO mapping (NOT AutoMapper, even though
// `abp new` ships AutoMapper by default). The scaffold tool swapped the
// AutoMapper packages for Mapperly during overlay application and added
// [DependsOn(typeof(AbpMapperlyModule))] to the application module.
//
// To add a new mapping:
//
// 1. Create a partial mapper class extending MapperBase<TSource, TDest>:
//
//    using Riok.Mapperly.Abstractions;
//    using Volo.Abp.Mapperly;
//
//    namespace ${PROJECT_NAME}.MyFeature;
//
//    [Mapper(RequiredMappingStrategy = RequiredMappingStrategy.Target)]
//    public partial class MyFeatureMapper : MapperBase<MyEntity, MyDto>
//    {
//        public override partial MyDto Map(MyEntity source);
//        public override partial void Map(MyEntity source, MyDto destination);
//    }
//
// 2. Register the singleton in ${PROJECT_NAME}ApplicationModule.ConfigureServices:
//
//    context.Services.AddSingleton<MyFeatureMapper>();
//
// 3. Inject MyFeatureMapper via constructor in your app service. NEVER
//    field-initialize with `new MyFeatureMapper()` — that bypasses DI and
//    breaks the test seam.
//
// Mapperly does NOT support multi-source mapping. For multi-source mappers,
// hand-write the class without [Mapper] and skip Mapperly's source generator.

namespace ${PROJECT_NAME};
