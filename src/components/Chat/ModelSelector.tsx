import { useState, useEffect, useRef } from 'react';
import { ChevronDown, Check } from 'lucide-react';
import { AppSettings } from '../../types';
import { fetchModels } from '../../services/gemini';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

export function ModelSelector({ 
  settings, 
  onUpdateSettings, 
  modelsOverride,
  onBlur,
}: { 
  settings: AppSettings, 
  onUpdateSettings: (s: AppSettings) => void, 
  modelsOverride?: string[],
  onBlur?: () => void,
}) {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);
  
  const models = modelsOverride || settings.availableModels || [];

  useEffect(() => {
    if (modelsOverride) return;

    const getModels = async () => {
      const fetchedModels = await fetchModels(settings);
      if (fetchedModels.length > 0) {
         if (JSON.stringify(fetchedModels) !== JSON.stringify(settings.availableModels)) {
            onUpdateSettings({ ...settings, availableModels: fetchedModels });
         }
      }
    };
    getModels();
  }, [settings.apiEndpoint]);

  const handleClickOutside = (event: MouseEvent) => {
    if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
      setIsOpen(false);
    }
  };

  useEffect(() => {
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  return (
    <div className="relative" ref={dropdownRef}>
      <div className="flex items-center gap-1 rounded-md border border-input bg-background p-0.5 w-full">
        <Input
          value={settings.modelName}
          onChange={(e) => onUpdateSettings({ ...settings, modelName: e.target.value })}
          onBlur={onBlur}
          className="h-8 border-none bg-transparent text-xs w-full focus-visible:ring-0"
          placeholder="选择或输入模型名称"
        />
        <Button 
            variant="ghost" 
            size="icon" 
            className="h-7 w-7 rounded-sm text-muted-foreground hover:text-primary flex-shrink-0" 
            onClick={() => setIsOpen(!isOpen)}
        >
          <ChevronDown size={14} />
        </Button>
      </div>
      {isOpen && models.length > 0 && (
        <div className="absolute top-10 left-0 right-0 z-[100] rounded-xl bg-popover border border-border shadow-lg overflow-y-auto py-1 max-h-60">
          {models.map(model => (
            <button
              key={model}
              className="flex w-full items-center justify-between px-4 py-2 text-xs hover:bg-muted text-left"
              onClick={() => {
                onUpdateSettings({ ...settings, modelName: model });
                setIsOpen(false);
              }}
            >
              <span className="truncate">{model}</span>
              {settings.modelName === model && <Check size={14} className="text-primary flex-shrink-0" />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
